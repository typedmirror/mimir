#!/usr/bin/env python3
"""
Parse mypy test-data/unit/check-*.test files, convert to mimir format,
run mimir check, and measure pass rate.

Usage:
    python3 tests/scripts/mypy_test_runner.py [--mypy-dir PATH] [--filter PATTERN] [--dry-run] [--verbose]
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class TestCase:
    name: str
    source_file: str
    code: str
    expected_error_lines: set
    has_extra_files: bool = False
    has_builtins: bool = False
    has_out_section: bool = False
    flags: str = ""
    skip: bool = False
    skip_reason: str = ""


@dataclass
class TestResult:
    case: TestCase
    passed: bool
    expected_errors: set
    actual_errors: set
    false_negatives: set    # expected but not found
    false_positives: set    # found but not expected
    mimir_output: str = ""


@dataclass
class CategoryResult:
    file_name: str
    total: int = 0
    passed: int = 0
    skipped: int = 0
    failed: int = 0
    fn_lines: int = 0
    fp_lines: int = 0


def parse_test_file(filepath: str) -> list[TestCase]:
    """Parse a mypy .test file into individual test cases."""
    cases = []
    with open(filepath) as f:
        content = f.read()

    case_pattern = re.compile(r'^\[case (\w+)(?:-(\w+))?\]\s*$', re.MULTILINE)
    matches = list(case_pattern.finditer(content))

    for i, match in enumerate(matches):
        name = match.group(1)
        suffix = match.group(2) or ""
        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(content)
        block = content[start:end].strip()

        lines = block.split('\n')
        code_lines = []
        expected_errors = set()
        has_extra_files = False
        has_builtins = False
        has_out_section = False
        flags = ""
        skip = False
        skip_reason = ""

        in_code = True
        line_num = 0
        prev_error_line = 0  # track continuation lines

        for line in lines:
            if line.startswith('[file '):
                has_extra_files = True
                in_code = False
                continue
            if line.startswith('[builtins ') or line.startswith('[typing '):
                has_builtins = True
                continue
            if line.startswith('[out]') or line.startswith('[out ') or line == '[out]':
                has_out_section = True
                in_code = False
                continue
            if line.startswith('[') and line.rstrip().endswith(']'):
                in_code = False
                continue
            if line.startswith('# flags:'):
                flags = line[8:].strip()
                continue
            if line.startswith('--'):
                continue

            if in_code:
                line_num += 1
                # Handle continuation lines: if previous # E: ended with \,
                # this line's # E: refers to the same source line
                is_continuation = (prev_error_line > 0 and
                                   re.match(r'^\s*#\s*[ENW]:', line))
                if re.search(r'#\s*E:', line):
                    if is_continuation:
                        expected_errors.add(prev_error_line)
                    else:
                        expected_errors.add(line_num)
                    clean = re.sub(r'\s*#\s*E:.*$', '', line)
                    # Track if this error line has continuation marker
                    if line.rstrip().endswith('\\'):
                        prev_error_line = line_num if not is_continuation else prev_error_line
                    else:
                        prev_error_line = 0
                    if is_continuation and clean.strip() == '':
                        line_num -= 1  # don't count pure continuation as a code line
                    else:
                        code_lines.append(clean)
                elif re.search(r'#\s*N:', line):
                    clean = re.sub(r'\s*#\s*N:.*$', '', line)
                    if is_continuation and clean.strip() == '':
                        line_num -= 1
                    else:
                        code_lines.append(clean)
                    prev_error_line = 0
                elif re.search(r'#\s*W:', line):
                    clean = re.sub(r'\s*#\s*W:.*$', '', line)
                    if is_continuation and clean.strip() == '':
                        line_num -= 1
                    else:
                        code_lines.append(clean)
                    prev_error_line = 0
                else:
                    # Bare continuation line after # E: ... \ — skip as code
                    if prev_error_line > 0:
                        line_num -= 1  # don't count as a code line
                        prev_error_line = 0
                    else:
                        code_lines.append(line)
                        prev_error_line = 0

        if has_extra_files:
            skip = True
            skip_reason = "multi-file"
        elif has_out_section and not expected_errors:
            skip = True
            skip_reason = "out-section-only"
        elif '--python-version 2' in flags:
            skip = True
            skip_reason = "python2"
        elif suffix in ('writescache', 'skip'):
            skip = True
            skip_reason = f"suffix-{suffix}"
        elif not code_lines or all(l.strip() == '' for l in code_lines):
            skip = True
            skip_reason = "empty"

        code = '\n'.join(code_lines) + '\n'

        cases.append(TestCase(
            name=name,
            source_file=os.path.basename(filepath),
            code=code,
            expected_error_lines=expected_errors,
            has_extra_files=has_extra_files,
            has_builtins=has_builtins,
            has_out_section=has_out_section,
            flags=flags,
            skip=skip,
            skip_reason=skip_reason,
        ))

    return cases


def run_mimir_check(code: str, mimir_bin: str, timeout: int = 10) -> tuple[set, str]:
    """Run mimir check on code, return (error_line_numbers, raw_output)."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as f:
        f.write(code)
        f.flush()
        tmppath = f.name

    try:
        result = subprocess.run(
            [mimir_bin, 'check', tmppath],
            capture_output=True, text=True, timeout=timeout
        )
        output = result.stdout + result.stderr

        error_lines = set()
        for line in output.strip().split('\n'):
            if not line.strip():
                continue
            # Only count error-severity diagnostics (not warnings like D001)
            # Match: path:line:col: error[CODE]: message
            if 'error[' not in line:
                continue
            m = re.match(r'.*?:(\d+):\d+:\s*error\[', line)
            if m:
                error_lines.add(int(m.group(1)))

        return error_lines, output
    except subprocess.TimeoutExpired:
        return set(), "TIMEOUT"
    except Exception as e:
        return set(), f"ERROR: {e}"
    finally:
        os.unlink(tmppath)


def evaluate_case(case: TestCase, mimir_bin: str) -> TestResult:
    """Run a single test case and evaluate results."""
    actual_errors, output = run_mimir_check(case.code, mimir_bin)

    expected = case.expected_error_lines
    false_negatives = expected - actual_errors
    false_positives = actual_errors - expected

    passed = len(false_negatives) == 0 and len(false_positives) == 0

    return TestResult(
        case=case,
        passed=passed,
        expected_errors=expected,
        actual_errors=actual_errors,
        false_negatives=false_negatives,
        false_positives=false_positives,
        mimir_output=output,
    )


def run_tests(mypy_dir: str, mimir_bin: str, file_filter: str = None,
              dry_run: bool = False, verbose: bool = False,
              max_cases: int = 0) -> dict:
    """Run all mypy tests and return results summary."""
    test_dir = os.path.join(mypy_dir, 'test-data', 'unit')
    pattern = os.path.join(test_dir, 'check-*.test')
    test_files = sorted(glob.glob(pattern))

    if file_filter:
        test_files = [f for f in test_files if file_filter in os.path.basename(f)]

    all_results = []
    category_results = {}
    total_cases = 0
    total_skipped = 0
    total_run = 0
    total_passed = 0

    for filepath in test_files:
        fname = os.path.basename(filepath)
        cases = parse_test_file(filepath)
        cat = CategoryResult(file_name=fname)

        for case in cases:
            total_cases += 1
            cat.total += 1

            if case.skip:
                total_skipped += 1
                cat.skipped += 1
                if verbose:
                    print(f"  SKIP {case.name} ({case.skip_reason})")
                continue

            if max_cases and total_run >= max_cases:
                break

            total_run += 1

            if dry_run:
                print(f"  DRY: {case.name} (expects {len(case.expected_error_lines)} errors)")
                continue

            result = evaluate_case(case, mimir_bin)
            all_results.append(result)

            if result.passed:
                total_passed += 1
                cat.passed += 1
                if verbose:
                    print(f"  PASS {case.name}")
            else:
                cat.failed += 1
                cat.fn_lines += len(result.false_negatives)
                cat.fp_lines += len(result.false_positives)
                if verbose:
                    fn_str = f"FN:{sorted(result.false_negatives)}" if result.false_negatives else ""
                    fp_str = f"FP:{sorted(result.false_positives)}" if result.false_positives else ""
                    print(f"  FAIL {case.name} {fn_str} {fp_str}")

        if max_cases and total_run >= max_cases:
            break

        category_results[fname] = cat
        if not dry_run:
            run_count = cat.total - cat.skipped
            rate = f"{cat.passed}/{run_count}" if run_count > 0 else "0/0"
            print(f"{fname}: {rate} passed ({cat.skipped} skipped)")

    print("\n" + "=" * 60)
    print("MYPY TEST SUITE RESULTS")
    print("=" * 60)
    print(f"Total cases:   {total_cases}")
    print(f"Skipped:       {total_skipped} (multi-file, out-only, python2, etc.)")
    print(f"Run:           {total_run}")
    if not dry_run:
        print(f"Passed:        {total_passed}")
        print(f"Failed:        {total_run - total_passed}")
        if total_run > 0:
            print(f"Pass rate:     {total_passed/total_run*100:.1f}%")

        print(f"\nTop failure categories:")
        sorted_cats = sorted(category_results.values(),
                           key=lambda c: c.failed, reverse=True)
        for cat in sorted_cats[:15]:
            if cat.failed > 0:
                run = cat.total - cat.skipped
                print(f"  {cat.file_name}: {cat.failed}/{run} failed "
                      f"(FN:{cat.fn_lines} FP:{cat.fp_lines})")

        total_fn = sum(len(r.false_negatives) for r in all_results)
        total_fp = sum(len(r.false_positives) for r in all_results)
        print(f"\nAggregate: {total_fn} false negative lines, {total_fp} false positive lines")

    return {
        'total': total_cases,
        'skipped': total_skipped,
        'run': total_run,
        'passed': total_passed,
        'failed': total_run - total_passed,
        'categories': {k: vars(v) for k, v in category_results.items()},
    }


def main():
    parser = argparse.ArgumentParser(description='Run mypy tests against mimir')
    parser.add_argument('--mypy-dir', default='/Users/ivermektin/Desktop/mypy',
                       help='Path to mypy repo')
    parser.add_argument('--mimir-bin', default='./mimir_bin',
                       help='Path to mimir binary')
    parser.add_argument('--filter', default=None,
                       help='Filter test files by name pattern')
    parser.add_argument('--dry-run', action='store_true',
                       help='Parse tests but do not run mimir')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Show individual test results')
    parser.add_argument('--max', type=int, default=0,
                       help='Max cases to run (0=all)')
    parser.add_argument('--json', default=None,
                       help='Write results to JSON file')
    args = parser.parse_args()

    if not os.path.isdir(args.mypy_dir):
        print(f"Error: mypy directory not found at {args.mypy_dir}")
        sys.exit(1)

    if not args.dry_run and not os.path.isfile(args.mimir_bin):
        print(f"Error: mimir binary not found at {args.mimir_bin}")
        sys.exit(1)

    results = run_tests(
        mypy_dir=args.mypy_dir,
        mimir_bin=args.mimir_bin,
        file_filter=args.filter,
        dry_run=args.dry_run,
        verbose=args.verbose,
        max_cases=args.max,
    )

    if args.json:
        with open(args.json, 'w') as f:
            json.dump(results, f, indent=2)
        print(f"\nResults written to {args.json}")


if __name__ == '__main__':
    main()
