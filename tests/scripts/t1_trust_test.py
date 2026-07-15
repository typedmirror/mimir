#!/usr/bin/env python3
"""
T1 TRUST regression suite — kills the silent-green cliff, permanently.

Covers (positive AND negative):
  a. B003 unresolved-import warning + end-of-run summary line
  b. Marker-less same-directory sibling resolution (incl. precedence: local
     shadows stdlib/installed; dotted/namespace targets)
  c. Unknown-cascade cap: checks not depending on unresolved symbols still fire
  d. P001 parse-drop warnings (statement drop + unexpected indent), analysis
     continues after the drop

Fixtures live permanently in tests/fixtures/trust_t1/. Each case directory is
copied to a temp dir before checking — REQUIRED, because inside this repo the
project-root auto-detection (.git) would promote single-file checks to
multi-file mode and defeat the exact no-marker scenario under test.

Usage:
    python3 tests/scripts/t1_trust_test.py [--mimir-bin ./mimir_bin]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures", "trust_t1")


def run_check(mimir_bin: str, case_dir: str, target_file: str):
    """Copy case_dir to a marker-free temp dir, run `mimir check <target>`."""
    tmp = tempfile.mkdtemp(prefix="t1trust_")
    try:
        dst = os.path.join(tmp, os.path.basename(case_dir))
        shutil.copytree(case_dir, dst)
        target = os.path.join(dst, target_file)
        proc = subprocess.run(
            [mimir_bin, "check", target],
            capture_output=True, text=True, timeout=30,
        )
        return proc.stdout + proc.stderr, proc.returncode
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# Each expectation: (kind, pattern)
#   present     — regex must match somewhere in output
#   absent      — regex must NOT match anywhere in output
#   exit        — pattern is the required exit code (int)
CASES = [
    ("sibling: no-marker sibling resolution catches planted bugs (T1b acceptance)",
     "sibling", "service.py", [
         ("present", r"service\.py:14:\d+: error\[T002\]"),   # BUG 1: str for int
         ("present", r"service\.py:30:\d+: error\[T003\]"),   # BUG 2: None vs Product
         ("present", r"service\.py:40:\d+: error\[T003\]"),   # BUG 4: float vs int
         ("absent",  r"B003"),                                # models resolved — no warning
         ("absent",  r"import\(s\) unresolved"),              # no summary
         ("exit", 1),
     ]),
    ("unresolved: loud B003 + summary; independent checks still fire (T1a + T1c)",
     "unresolved", "lone_unresolved.py", [
         ("present", r"warning\[B003\].*nonexistent_xyz_pkg"),
         ("present", r"import\(s\) unresolved — type coverage incomplete"),
         ("present", r"lone_unresolved\.py:7:\d+: error\[T005\]"),   # str + int, independent
         ("present", r"lone_unresolved\.py:10:\d+: error\[T005\]"),  # not-callable, independent
         ("absent",  r"lone_unresolved\.py:1[45]:\d+: error"),       # Unknown-touching lines stay quiet
         ("exit", 1),
     ]),
    ("relative: package-relative import in single-file mode → B003; summary on SUCCESS exit",
     "relative", "rel_import.py", [
         ("present", r"warning\[B003\].*'\.sib'"),
         ("present", r"package-relative"),
         ("present", r"import\(s\) unresolved — type coverage incomplete"),
         ("absent",  r"error\["),
         ("exit", 0),   # warnings only — summary must print on the success path too
     ]),
    ("parse_drop/stmt: P001 statement drop (one per line) + analysis continues (T1d)",
     "parse_drop", "drop_stmt.py", [
         ("present", r"warning\[P001\].*statement dropped"),
         ("present", r"drop_stmt\.py:5:\d+: error\[T001\]"),  # post-drop line still checked
         ("exit", 1),
     ]),
    ("parse_drop/indent: P001 unexpected indentation (T1d)",
     "parse_drop", "drop_indent.py", [
         ("present", r"warning\[P001\].*unexpected indentation"),
         ("exit", 0),
     ]),
    ("clean: FP guard — resolvable imports produce NO B003/P001/summary",
     "clean", "clean_app.py", [
         ("absent", r"B003"),
         ("absent", r"P001"),
         ("absent", r"import\(s\) unresolved"),
         ("absent", r"error\["),
         ("exit", 0),
     ]),
    ("precedence: local sibling SHADOWS stdlib module of the same name (sys.path[0] parity)",
     "precedence", "uses_json.py", [
         ("present", r"uses_json\.py:9:\d+: error\[T001\]"),  # only fires if sibling json.py won
         ("absent",  r"B003"),
         ("exit", 1),
     ]),
    ("dotted: dotted sibling target (mypkg/util.py, namespace style) resolves",
     "dotted", "dotted_main.py", [
         ("present", r"dotted_main\.py:7:\d+: error\[T001\]"),  # only fires if types flowed
         ("absent",  r"B003"),
         ("exit", 1),
     ]),
    ("t2/typevar-d001: annotation-used TypeVars never D001; dead ones still flagged",
     "typevar_d001", "typevars.py", [
         ("absent",  r"D001\]: variable '[TUQAF]'"),            # all used TypeVars clean
         ("present", r"D001\]: variable 'DEAD'"),               # dead TypeVar still flagged
         ("present", r"D001\]: variable 'unused_local'"),       # normal D001 unaffected
         ("absent",  r"error\["),
         ("exit", 0),
     ]),
]


def t5_crash_checks(mimir_bin: str) -> int:
    """T5 (S111): is_assignable cycle-guard crash regressions.

    These exercise the cached-package deep-check path, which depends on
    ~/.mimir/cache/packages/ state — environment-dependent by nature (that is
    WHY conform/mypy never caught the crash). When the cache is absent they
    SKIP LOUDLY rather than pass silently. The hermetic core fixture is
    tests/conformance/t5_self_recursive_assign.py (runs in `mimir conform`).
    """
    repo_root = os.path.join(os.path.dirname(__file__), "..", "..")
    cache = os.path.expanduser("~/.mimir/cache/packages")
    have_cached = any(
        os.path.isdir(os.path.join(cache, pkg)) for pkg in ("requests", "urllib3")
    )

    def check_no_signal(name: str, target_code: str = None, target_path: str = None,
                        timeout: int = 180) -> bool:
        if target_code is not None:
            import tempfile as _tf
            with _tf.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
                f.write(target_code)
                target_path = f.name
        try:
            proc = subprocess.run([mimir_bin, "check", target_path],
                                  capture_output=True, text=True, timeout=timeout)
            if proc.returncode < 0:
                print(f"FAIL  t5/{name}: killed by signal {-proc.returncode} (crash regression)")
                return False
            print(f"PASS  t5/{name} (exit {proc.returncode}, no signal)")
            return True
        except subprocess.TimeoutExpired:
            print(f"FAIL  t5/{name}: timeout")
            return False
        finally:
            if target_code is not None:
                os.unlink(target_path)

    failures = 0
    if have_cached:
        if not check_no_signal("import-requests", target_code="import requests\n"):
            failures += 1
        if not check_no_signal("import-urllib3", target_code="import urllib3\n"):
            failures += 1
    else:
        print("SKIP  t5/import-requests, t5/import-urllib3 — ~/.mimir/cache/packages "
              "has neither requests nor urllib3; the cached-package crash path is "
              "NOT exercised on this machine (environment-dependent check)")

    for rel in ("tests/conformance/conc_blocking.py",
                "tests/conformance/sec_supply_chain.py"):
        p = os.path.join(repo_root, rel)
        if os.path.isfile(p):
            if not check_no_signal(os.path.basename(rel), target_path=p):
                failures += 1
    # Directory mode over the whole conformance corpus — no crash allowed
    if not check_no_signal("conformance-dir-mode",
                           target_path=os.path.join(repo_root, "tests", "conformance")):
        failures += 1
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mimir-bin", default="./mimir_bin")
    args = ap.parse_args()

    if not os.path.isfile(args.mimir_bin):
        print(f"error: mimir binary not found at {args.mimir_bin} "
              f"(build with: odin build src/ -collection:mimir=src/ -out:mimir -o:speed && cp mimir mimir_bin)")
        return 2

    failures = 0
    for name, case_dir, target, expectations in CASES:
        output, exit_code = run_check(
            args.mimir_bin, os.path.join(FIXTURES, case_dir), target)
        problems = []
        for kind, pattern in expectations:
            if kind == "present" and not re.search(pattern, output):
                problems.append(f"MISSING  /{pattern}/")
            elif kind == "absent" and re.search(pattern, output):
                problems.append(f"FORBIDDEN /{pattern}/ matched")
            elif kind == "exit" and exit_code != pattern:
                problems.append(f"EXIT {exit_code} != expected {pattern}")
        if problems:
            failures += 1
            print(f"FAIL  {name}")
            for p in problems:
                print(f"      {p}")
            print("      ---- output ----")
            for line in output.strip().split("\n"):
                print(f"      {line}")
        else:
            print(f"PASS  {name}")

    t5_failures = t5_crash_checks(args.mimir_bin)
    failures += t5_failures

    total = len(CASES)
    print(f"\nt1_trust: {total - (failures - t5_failures)}/{total} fixture cases passed"
          f"{'' if t5_failures == 0 else f'; {t5_failures} t5 crash check(s) FAILED'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
