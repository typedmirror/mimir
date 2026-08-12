#!/usr/bin/env python3
"""
Sweep mimir against the official python/typing conformance test suite
(github.com/python/typing, conformance/tests/*.py) and produce a
line-level hit-rate scorecard.

This is NOT the suite's own scoring harness (conformance/src/main.py,
which needs `uv` + Python 3.12 + per-checker adapters and produces a
spec-clause-level score). It is a cheap, honest, line-level snapshot:

  1. For each conformance/tests/*.py file (excluding underscore-prefixed
     helper modules — those are never scored on their own, only imported),
     copy it, plus any same-directory underscore-prefixed helper modules
     it imports, into an isolated scratch directory with no __init__.py.
     This makes mimir treat it as a standalone single-file check instead
     of pulling in the whole `typing` repo (which it does if run in
     place — the suite's own conformance/src/ has an __init__.py, and
     mimir's multi-file mode walks up to it).
  2. Run `mimir check <file>` on the isolated copy, capture
     stdout+stderr+exit code, with a 60s per-file timeout.
  3. Parse the suite's own `# E` / `# E: <text>` / `# E[tag]` /
     `# E[tag+]` markers (required — an error must land on that line)
     and `# E?` markers (optional — excluded from scoring in both
     directions, per the suite's own README convention).
  4. For every required-error line: did mimir emit ANY `error[...]`
     diagnostic on that exact line? Hit, or miss.
  5. False positives: mimir `error[...]` diagnostics on lines that carry
     NO `# E` marker of any kind (required or optional).
  6. Aggregate by category = the file's name up to the first underscore
     (the suite's own grouping convention, e.g. generics_basic.py ->
     "generics").

What this deliberately does NOT do: match diagnostic codes to specific
spec clauses, credit partial/near-miss types, run the suite's `# E[tag]`
multiplicity rule (a tagged line is scored the same as a plain required
line here — "the exact line must get an error" — which is slightly
stricter than the suite's own "exactly one line in the tag group" rule
in edge cases), or account for assert_type()/reveal_type() semantic
checks beyond whatever plain error/warning diagnostics mimir happens to
emit. It is a coarse proxy, not a certification. Only `error[...]`
diagnostics count (not `warning[...]`), matching mimir's own severity
split.

The suite is NOT vendored in this repo, and — unlike the mypy corpus
(tests/scripts/MYPY_DEP.md) — is NOT pinned to one commit. Upstream
`python/typing` moves; this method is expected to drift as it does.
Publish whatever this script measures against your checkout, and always
record the checkout's commit hash next to the numbers — a number without
its commit hash is not comparable to anything.

Usage:
    python3 tests/scripts/official_typing_scorecard.py [--suite-dir PATH] [--mimir-bin PATH] [--json OUT] [--verbose]

Fetch the suite (any commit — none is pinned):
    git clone --depth 1 https://github.com/python/typing.git /path/to/typing-suite
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field

MARKER_RE = re.compile(r'#\s*E(\?)?(\[[^\]]*\])?(?=[:\s]|$)')
ERROR_LINE_RE = re.compile(r'^\S*?:(\d+):\d+:\s*error\[')
IMPORT_RE = re.compile(r'^(?:from|import)\s+(_[A-Za-z_][A-Za-z0-9_]*)', re.MULTILINE)


@dataclass
class FileResult:
    name: str
    category: str
    required: int = 0
    hit: int = 0
    fp: int = 0
    optional: int = 0
    crashed: bool = False
    timed_out: bool = False
    miss_lines: list = field(default_factory=list)
    fp_lines: list = field(default_factory=list)


def parse_markers(source: str) -> tuple[set, set]:
    """Return (required_lines, optional_lines), both 1-indexed line numbers.

    Skips lines that are themselves entirely a comment (stripped line starts
    with '#') even if they contain an "# E" marker substring — these are
    disabled example code in the suite (e.g. `# bad: f(x)  # E: ...`) that
    no checker can ever report an error on, since there is no code on that
    line to check. Counting them as required would inflate the denominator
    with lines that are unhittable by construction.
    """
    required, optional = set(), set()
    for i, line in enumerate(source.splitlines(), start=1):
        if '#' not in line:
            continue
        if line.lstrip().startswith('#'):
            continue
        m = MARKER_RE.search(line)
        if not m:
            continue
        if m.group(1):  # '?' present -> optional
            optional.add(i)
        else:
            required.add(i)
    return required, optional


def find_helper_imports(source: str) -> list[str]:
    """Underscore-prefixed same-directory modules this file imports."""
    return sorted(set(IMPORT_RE.findall(source)))


def run_mimir(mimir_bin: str, filepath: str, timeout: int) -> tuple[set, bool, bool, str]:
    """Returns (error_lines, crashed, timed_out, raw_output)."""
    try:
        result = subprocess.run(
            [mimir_bin, 'check', filepath],
            capture_output=True, text=True, timeout=timeout,
        )
        output = result.stdout + result.stderr
        crashed = result.returncode < 0  # killed by signal
        error_lines = set()
        for line in output.splitlines():
            m = ERROR_LINE_RE.match(line)
            if m:
                error_lines.add(int(m.group(1)))
        return error_lines, crashed, False, output
    except subprocess.TimeoutExpired:
        return set(), False, True, "TIMEOUT"
    except Exception as e:
        return set(), True, False, f"ERROR: {e}"


def sweep(suite_dir: str, mimir_bin: str, timeout: int, verbose: bool) -> dict:
    tests_dir = os.path.join(suite_dir, 'conformance', 'tests')
    all_files = sorted(glob.glob(os.path.join(tests_dir, '*.py')))
    scored_files = [f for f in all_files if not os.path.basename(f).startswith('_')]

    results: list[FileResult] = []
    total_required = total_hit = total_fp = total_optional = 0
    crashes = timeouts = 0

    with tempfile.TemporaryDirectory(prefix='mimir_typing_scorecard_') as tmproot:
        for filepath in scored_files:
            fname = os.path.basename(filepath)
            category = fname.split('_', 1)[0].removesuffix('.py')
            with open(filepath) as f:
                source = f.read()

            required, optional = parse_markers(source)

            # Isolate: fresh subdir per file, no __init__.py anywhere in it.
            scratch = os.path.join(tmproot, os.path.splitext(fname)[0])
            os.makedirs(scratch, exist_ok=True)
            dst = os.path.join(scratch, fname)
            shutil.copyfile(filepath, dst)

            for helper in find_helper_imports(source):
                for ext in ('.py', '.pyi'):
                    src_helper = os.path.join(tests_dir, helper + ext)
                    if os.path.isfile(src_helper):
                        shutil.copyfile(src_helper, os.path.join(scratch, helper + ext))

            error_lines, crashed, timed_out, output = run_mimir(mimir_bin, dst, timeout)
            if crashed:
                crashes += 1
            if timed_out:
                timeouts += 1

            hit_lines = required & error_lines
            miss_lines = required - error_lines
            fp_lines = error_lines - required - optional

            fr = FileResult(
                name=fname, category=category,
                required=len(required), hit=len(hit_lines), fp=len(fp_lines),
                optional=len(optional), crashed=crashed, timed_out=timed_out,
                miss_lines=sorted(miss_lines), fp_lines=sorted(fp_lines),
            )
            results.append(fr)
            total_required += fr.required
            total_hit += fr.hit
            total_fp += fr.fp
            total_optional += fr.optional

            if verbose:
                status = 'CRASH' if crashed else 'TIMEOUT' if timed_out else 'ok'
                print(f"  {fname}: {fr.hit}/{fr.required} hit, {fr.fp} FP [{status}]")

    categories: dict[str, dict] = {}
    for fr in results:
        c = categories.setdefault(fr.category, {
            'files': 0, 'required': 0, 'hit': 0, 'fp': 0,
        })
        c['files'] += 1
        c['required'] += fr.required
        c['hit'] += fr.hit
        c['fp'] += fr.fp

    return {
        'files_swept': len(scored_files),
        'crashes': crashes,
        'timeouts': timeouts,
        'total_required': total_required,
        'total_hit': total_hit,
        'total_fp': total_fp,
        'total_optional': total_optional,
        'files_zero_hit': sum(1 for fr in results if fr.required > 0 and fr.hit == 0),
        'files_clean': sum(1 for fr in results if fr.required > 0 and fr.hit == fr.required and fr.fp == 0),
        'categories': categories,
        'per_file': {fr.name: vars(fr) for fr in results},
    }


def print_report(data: dict, suite_commit: str):
    req, hit, fp = data['total_required'], data['total_hit'], data['total_fp']
    rate = (hit / req * 100) if req else 0.0
    print("\n" + "=" * 60)
    print("OFFICIAL PYTHON/TYPING CONFORMANCE SCORECARD")
    print("=" * 60)
    print(f"Suite commit:             {suite_commit}")
    print(f"Files swept:               {data['files_swept']}")
    print(f"Crashes:                   {data['crashes']}")
    print(f"Timeouts:                  {data['timeouts']}")
    print(f"Required-error lines:      {req}")
    print(f"Lines hit:                 {hit}")
    print(f"Overall hit rate:          {rate:.1f}%")
    print(f"False-positive lines:      {fp}")
    print(f"Optional (# E?) lines:     {data['total_optional']} (excluded from scoring)")
    print(f"Files 0/N hit:             {data['files_zero_hit']}/{data['files_swept']}")
    print(f"Files fully clean:         {data['files_clean']}/{data['files_swept']}")

    print("\nBy category (sorted by hit rate):")
    cats = []
    for name, c in data['categories'].items():
        r = (c['hit'] / c['required'] * 100) if c['required'] else 0.0
        cats.append((name, c['files'], c['required'], c['hit'], r, c['fp']))
    cats.sort(key=lambda t: t[4], reverse=True)
    for name, files, required, hit_, rate_, fp_ in cats:
        if required == 0:
            continue
        print(f"  {name:20s} files={files:3d} required={required:4d} "
              f"hit={hit_:4d} ({rate_:5.1f}%) fp={fp_:4d}")


def main():
    parser = argparse.ArgumentParser(
        description='Sweep mimir against the python/typing conformance suite')
    parser.add_argument(
        '--suite-dir',
        default=os.environ.get('TYPING_SUITE_DIR', 'typing-suite'),
        help='Path to a checkout of github.com/python/typing (env: TYPING_SUITE_DIR)')
    parser.add_argument('--mimir-bin', default='./mimir_bin',
                         help='Path to mimir binary')
    parser.add_argument('--timeout', type=int, default=60,
                         help='Per-file timeout in seconds (default 60)')
    parser.add_argument('--verbose', '-v', action='store_true')
    parser.add_argument('--json', default=None, help='Write full results to JSON file')
    args = parser.parse_args()

    tests_dir = os.path.join(args.suite_dir, 'conformance', 'tests')
    if not os.path.isdir(tests_dir):
        print(f"Error: suite not found at {args.suite_dir}")
        print(f"       (expected {tests_dir} to exist)")
        print("This suite is not vendored and not pinned to a commit. Fetch any")
        print("checkout with:")
        print(f"    git clone --depth 1 https://github.com/python/typing.git {args.suite_dir}")
        sys.exit(1)

    if not os.path.isfile(args.mimir_bin):
        print(f"Error: mimir binary not found at {args.mimir_bin}")
        sys.exit(1)

    suite_commit = 'unknown'
    try:
        head = subprocess.run(
            ['git', '-C', args.suite_dir, 'rev-parse', 'HEAD'],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        if head:
            suite_commit = head
    except (OSError, subprocess.TimeoutExpired):
        pass

    print(f"Sweeping {tests_dir} (commit {suite_commit}) with {args.mimir_bin} ...")
    data = sweep(args.suite_dir, args.mimir_bin, args.timeout, args.verbose)
    print_report(data, suite_commit)

    if args.json:
        with open(args.json, 'w') as f:
            json.dump({'suite_commit': suite_commit, **data}, f, indent=2)
        print(f"\nResults written to {args.json}")


if __name__ == '__main__':
    main()
