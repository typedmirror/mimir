#!/usr/bin/env python3
"""
Mypy test triage: ranked fix lists for d1-FP and d1-FN patterns.
Outputs the highest-impact patterns to fix, with specific test names and code.

Usage:
    python3 tests/scripts/triage.py [--save baseline.json] [--diff baseline.json]
"""

import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict

# Reuse the test runner's infrastructure
sys.path.insert(0, os.path.dirname(__file__))
from mypy_test_runner import parse_test_file, evaluate_case


def extract_error_info(output: str) -> list[dict]:
    """Extract error code, line, and message from mimir output."""
    errors = []
    for line in output.strip().split('\n'):
        if 'error[' not in line:
            continue
        m = re.match(r'.*?:(\d+):\d+:\s*error\[(\w+)\]:\s*(.*)', line)
        if m:
            errors.append({
                'line': int(m.group(1)),
                'code': m.group(2),
                'msg': m.group(3).strip(),
            })
    return errors


def extract_expected_category(case_code: str, fn_line: int) -> str:
    """Try to infer the expected error category from the test code."""
    lines = case_code.split('\n')
    if fn_line > len(lines):
        return 'unknown'
    code_line = lines[fn_line - 1].strip()

    # Simple heuristics
    if '=' in code_line and 'def ' not in code_line:
        return 'assignment'
    if 'def ' in code_line and '->' in code_line:
        return 'return'
    if '(' in code_line:
        return 'call'
    if '.' in code_line:
        return 'attribute'
    return 'other'


def run_triage(mypy_dir: str, mimir_bin: str, save_path: str = None,
               diff_path: str = None, top_n: int = 20):
    test_dir = os.path.join(mypy_dir, 'test-data', 'unit')
    pattern = os.path.join(test_dir, 'check-*.test')
    test_files = sorted(glob.glob(pattern))

    d1_fp = defaultdict(list)  # error_code → [(test_name, fp_line, code_at_line, msg)]
    d1_fn = defaultdict(list)  # category → [(test_name, fn_line, code_at_line)]
    all_results = {}  # test_name → {'passed': bool, 'fn': set, 'fp': set}

    total_run = 0
    total_passed = 0
    total_fp_lines = 0
    total_fn_lines = 0

    for filepath in test_files:
        cases = parse_test_file(filepath)
        for case in cases:
            if case.skip:
                continue
            total_run += 1
            result = evaluate_case(case, mimir_bin)

            if result.passed:
                total_passed += 1

            total_fp_lines += len(result.false_positives)
            total_fn_lines += len(result.false_negatives)

            all_results[case.name] = {
                'passed': result.passed,
                'fn': sorted(result.false_negatives),
                'fp': sorted(result.false_positives),
                'file': case.source_file,
            }

            code_lines = case.code.split('\n')

            # d1-FP: 0 FN, exactly 1 FP
            if not result.passed and len(result.false_negatives) == 0 and len(result.false_positives) == 1:
                fp_line = list(result.false_positives)[0]
                code_at = code_lines[fp_line - 1].strip()[:80] if fp_line <= len(code_lines) else '?'
                errors = extract_error_info(result.mimir_output)
                err_code = 'unknown'
                err_msg = ''
                for e in errors:
                    if e['line'] == fp_line:
                        err_code = e['code']
                        err_msg = e['msg'][:60]
                        break
                d1_fp[err_code].append({
                    'name': case.name,
                    'file': case.source_file,
                    'line': fp_line,
                    'code': code_at,
                    'msg': err_msg,
                })

            # d1-FN: exactly 1 FN, 0 FP
            if not result.passed and len(result.false_negatives) == 1 and len(result.false_positives) == 0:
                fn_line = list(result.false_negatives)[0]
                code_at = code_lines[fn_line - 1].strip()[:80] if fn_line <= len(code_lines) else '?'
                cat = extract_expected_category(case.code, fn_line)
                d1_fn[cat].append({
                    'name': case.name,
                    'file': case.source_file,
                    'line': fn_line,
                    'code': code_at,
                })

    # Output
    print("=" * 70)
    print(f"MYPY TRIAGE — {total_passed}/{total_run} passed ({total_passed/total_run*100:.1f}%)")
    print(f"FP lines: {total_fp_lines}  FN lines: {total_fn_lines}")
    print("=" * 70)

    # d1-FP ranked
    total_d1fp = sum(len(v) for v in d1_fp.values())
    print(f"\n--- d1-FP: {total_d1fp} tests (0 FN, 1 FP — fix the FP to flip) ---")
    for code in sorted(d1_fp, key=lambda c: -len(d1_fp[c])):
        tests = d1_fp[code]
        print(f"\n  {code}: {len(tests)} tests")
        for t in tests[:3]:
            print(f"    {t['name']} L{t['line']}: {t['code'][:50]}")
            if t['msg']:
                print(f"      → {t['msg']}")
        if len(tests) > 3:
            print(f"    ... and {len(tests) - 3} more")

    # d1-FN ranked
    total_d1fn = sum(len(v) for v in d1_fn.values())
    print(f"\n--- d1-FN: {total_d1fn} tests (1 FN, 0 FP — add the check to flip) ---")
    for cat in sorted(d1_fn, key=lambda c: -len(d1_fn[c])):
        tests = d1_fn[cat]
        print(f"\n  {cat}: {len(tests)} tests")
        for t in tests[:3]:
            print(f"    {t['name']} L{t['line']}: {t['code'][:50]}")
        if len(tests) > 3:
            print(f"    ... and {len(tests) - 3} more")

    # Save baseline
    if save_path:
        baseline = {
            'total_run': total_run,
            'total_passed': total_passed,
            'total_fp': total_fp_lines,
            'total_fn': total_fn_lines,
            'results': all_results,
        }
        with open(save_path, 'w') as f:
            json.dump(baseline, f, indent=2, default=list)
        print(f"\nBaseline saved to {save_path}")

    # Diff against baseline
    if diff_path and os.path.exists(diff_path):
        with open(diff_path) as f:
            baseline = json.load(f)

        old_passed = set(n for n, r in baseline['results'].items() if r['passed'])
        new_passed = set(n for n, r in all_results.items() if r['passed'])

        gained = new_passed - old_passed
        lost = old_passed - new_passed

        print(f"\n--- DELTA from {diff_path} ---")
        print(f"  Passed: {baseline['total_passed']} → {total_passed} ({total_passed - baseline['total_passed']:+d})")
        print(f"  FP: {baseline['total_fp']} → {total_fp_lines} ({total_fp_lines - baseline['total_fp']:+d})")
        print(f"  FN: {baseline['total_fn']} → {total_fn_lines} ({total_fn_lines - baseline['total_fn']:+d})")
        if gained:
            print(f"\n  GAINED ({len(gained)}):")
            for name in sorted(gained)[:20]:
                print(f"    + {name}")
            if len(gained) > 20:
                print(f"    ... and {len(gained) - 20} more")
        if lost:
            print(f"\n  LOST ({len(lost)}):")
            for name in sorted(lost)[:20]:
                r = all_results.get(name, {})
                print(f"    - {name} (FN:{r.get('fn', [])}, FP:{r.get('fp', [])})")
            if len(lost) > 20:
                print(f"    ... and {len(lost) - 20} more")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Mypy test triage')
    parser.add_argument('--mypy-dir', default='/Users/ivermektin/Desktop/mypy')
    parser.add_argument('--mimir-bin', default='./mimir_bin')
    parser.add_argument('--save', help='Save baseline to JSON file')
    parser.add_argument('--diff', help='Diff against saved baseline JSON')
    parser.add_argument('--top', type=int, default=20, help='Show top N patterns')
    args = parser.parse_args()

    if not os.path.isdir(args.mypy_dir):
        print(f"Error: mypy directory not found at {args.mypy_dir}")
        sys.exit(1)
    if not os.path.isfile(args.mimir_bin):
        print(f"Error: mimir binary not found at {args.mimir_bin}")
        sys.exit(1)

    run_triage(args.mypy_dir, args.mimir_bin, save_path=args.save,
               diff_path=args.diff, top_n=args.top)
