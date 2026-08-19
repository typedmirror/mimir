#!/usr/bin/env python3
"""
S114 launch-blocker regression: `mimir check <path>` must behave identically
regardless of whether <path> is given in relative or absolute form, and a
single-.py-file target must NEVER silently expand into a whole-project or
whole-repo check.

Background (docs/DECISIONS.md, S114): `mimir check <abs-path-to-one-file>`
walked ALL real filesystem ancestors of the target looking for a project
marker (.git/pyproject.toml/mimir.toml/setup.py) via
core.find_project_root, while `mimir check <rel-path-to-the-SAME-file>` did
not — find_project_root's up-walk loop had a fallback to "." only in its
FIRST strip, not in the repeated up-walk strip, so a relative target's walk
silently died one level too early and never reached the repo's own .git.
Net effect: identical file, different flags-free invocation, wildly
different behavior — an absolute-path single-file check of one fixture
walked the ENTIRE repository (thousands of files), including
.claude/worktrees/ (other agents' full repo checkouts on disk, since
.claude was never in IGNORE_DIRS). Ruled fix (docs/DECISIONS.md, Option A):
`mimir check file.py` always means exactly that file, for both path forms;
project-root ancestor-walk promotion is removed entirely (the narrower,
already-symmetric __init__.py-sibling package promotion is unaffected);
directory walks never descend into dot-directories.

Covers (positive AND negative):
  a. rel vs abs path, same file, same flags -> identical diagnostics content
     (mod the path string itself, which necessarily differs by construction
     of the input), identical file-count trailer, identical exit code.
  b. abs-path check of a single conformance fixture emits ONLY that
     fixture's diagnostics -- not the whole corpus/repo. This is the exact
     regression: pre-fix, this invocation reported hundreds/thousands of
     files and errors from files that were never named on the command line.
  c. Directory walks never descend into dot-directories (e.g. a `.claude`
     sibling holding files that would fire loud diagnostics if seen) --
     proven against an ISOLATED TEMP-DIR fixture created by this script,
     never the live repo .claude/ (which holds other agents' worktrees and
     must not be depended on).

Usage:
    python3 tests/scripts/check_path_form_test.py [--mimir-bin ./mimir_bin]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# A real, permanent conformance fixture with exactly one diagnostic-bearing
# line, no __init__.py sibling in its directory (so the narrower package
# promotion never applies either) -- isolates the ancestor-walk bug cleanly.
FIXTURE_REL = "tests/conformance/gap_data002.py"


def run(mimir_bin: str, args, cwd=None, timeout=60):
    proc = subprocess.run(
        [mimir_bin] + args, capture_output=True, text=True, timeout=timeout, cwd=cwd,
    )
    return proc.stdout + proc.stderr, proc.returncode


def test_rel_vs_abs_identical(mimir_bin: str) -> list:
    """(a) + (b): rel and abs invocations of ONE fixture file produce the
    same content (modulo the path string itself) and both stay single-file."""
    problems = []
    rel_target = FIXTURE_REL
    abs_target = os.path.join(REPO_ROOT, FIXTURE_REL)

    rel_out, rel_exit = run(mimir_bin, ["check", rel_target], cwd=REPO_ROOT)
    abs_out, abs_exit = run(mimir_bin, ["check", abs_target], cwd=REPO_ROOT)

    if rel_exit != abs_exit:
        problems.append(f"exit code differs: rel={rel_exit} abs={abs_exit}")

    # Normalize the one expected difference -- the printed path itself --
    # then require byte-identical content.
    abs_out_normalized = abs_out.replace(abs_target, rel_target)
    if abs_out_normalized != rel_out:
        problems.append(
            "output differs after path normalization (should be byte-identical):\n"
            f"      ---- rel ----\n      " + "\n      ".join(rel_out.strip().split("\n")) +
            f"\n      ---- abs (normalized) ----\n      " +
            "\n      ".join(abs_out_normalized.strip().split("\n"))
        )

    # (b) single-file mode must stay single-file: exactly one file checked,
    # never a corpus-wide/repo-wide walk.
    # Three single-file trailer forms exist (main.odin): clean success
    # ("successfully checked 1 file(s)"), the shared multi-file-style error
    # count ("N error(s) in 1 file(s)", used on parse-error-free error exits
    # from some call sites), and cmd_check_single's own error trailer
    # ("1 file(s) had errors", main.odin:1671/1708 -- hit whenever the
    # single-file target itself has an Error-severity diagnostic, e.g. a
    # DATA002/DB002/JSON002/JSON003 fixture under the now-fixed
    # registry-reinit path). All three assert "stayed single-file"; only the
    # exact wording differs by call site.
    TRAILER_RE = r"successfully checked 1 file\(s\)|\d+ error\(s\) in 1 file\(s\)|\d+ file\(s\) had errors"
    if not re.search(TRAILER_RE, rel_out):
        problems.append(f"rel output does not show a 1-file-checked trailer:\n      {rel_out!r}")
    if not re.search(TRAILER_RE, abs_out):
        problems.append(f"abs output does not show a 1-file-checked trailer (LAUNCH-BLOCKER "
                         f"REGRESSION: abs-path single-file check silently promoted to "
                         f"project/multi-file mode):\n      {abs_out!r}")

    # No other conformance fixture's name may appear anywhere in the output
    # of either invocation -- proves neither form walked the corpus.
    other_fixture = "gap_ser002.py"
    if other_fixture in rel_out or other_fixture in abs_out:
        problems.append(f"output mentions an unrelated fixture ({other_fixture}) -- "
                         f"single-file check leaked into a directory/project walk")

    return problems


def test_dotdir_excluded(mimir_bin: str) -> list:
    """(c) Directory walks never descend into dot-directories. Uses an
    isolated temp-dir fixture (never the live repo .claude/)."""
    problems = []
    tmp = tempfile.mkdtemp(prefix="pathform_dotdir_")
    try:
        proj = os.path.join(tmp, "proj")
        os.makedirs(proj)
        with open(os.path.join(proj, "good.py"), "w") as f:
            f.write("x: int = 1\n")

        hidden = os.path.join(proj, ".claude")
        os.makedirs(hidden)
        # A distinctively-named file that WOULD fire a loud diagnostic
        # (undefined name -> B001) if the walker ever descended into the
        # dot-directory. Its presence in output is the failure signal.
        with open(os.path.join(hidden, "should_never_be_scanned.py"), "w") as f:
            f.write("this_name_does_not_exist_anywhere()\n")

        for label, target in (("abs", proj), ("rel", "proj")):
            cwd = tmp if label == "rel" else None
            out, exit_code = run(mimir_bin, ["check", target], cwd=cwd)
            if "should_never_be_scanned" in out or ".claude" in out:
                problems.append(
                    f"[{label}] directory walk descended into .claude/ -- "
                    f"found forbidden content in output:\n      {out!r}"
                )
            if "good.py" not in out:
                problems.append(f"[{label}] expected good.py to be checked but it wasn't:\n      {out!r}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mimir-bin", default="./mimir_bin")
    args = ap.parse_args()

    mimir_bin = os.path.abspath(args.mimir_bin)
    if not os.path.isfile(mimir_bin):
        print(f"error: mimir binary not found at {mimir_bin} "
              f"(build with: odin build src/ -collection:mimir=src/ -out:mimir -o:speed && cp mimir mimir_bin)")
        return 2

    cases = [
        ("rel-vs-abs: single-file check identical + stays single-file (a+b)", test_rel_vs_abs_identical),
        ("dotdir: directory walk never descends into .claude/ or hidden dirs (c)", test_dotdir_excluded),
    ]

    failures = 0
    for name, fn in cases:
        problems = fn(mimir_bin)
        if problems:
            failures += 1
            print(f"FAIL  {name}")
            for p in problems:
                print(f"      {p}")
        else:
            print(f"PASS  {name}")

    total = len(cases)
    print(f"\ncheck_path_form: {total - failures}/{total} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
