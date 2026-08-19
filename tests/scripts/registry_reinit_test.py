#!/usr/bin/env python3
"""
S-G6 (Phase G, lane L5) registry-reinit regression: DB002/JSON002/JSON003/
DATA002 must fire under CLI project-mode `mimir check` (not just under
`mimir conform`).

Background (docs/DECISIONS.md, docs/FACTORY_CONTRACT_G.md D-G6v2):
`checker.init_virtual_registry` (src/checker/virtual_modules.odin) registers
every mimir.* virtual-module export via `register_type`, which ALWAYS
appends a fresh Type_ID, and stores several of those exports as singleton
fields on the shared Type_Registry (json_parse_type, db_query_type,
data_read_csv_type/data_read_json_type/data_read_parquet_type, etc.).
Every project-mode check path calls this proc TWICE against the SAME live
registry: once at orchestrator project-setup (which builds import_types
from that call's Type_IDs) and again per module inside
checker._check_with_resolution (Full_Single AND Full_Multi resolution
policies both route there). The second call silently reassigns those
singleton fields to NEW Type_IDs that no longer match the ones baked into
import_types from the first call, so identity checks like
`func_type == ctx.reg.json_parse_type` (src/checker/infer.odin) never match
and the DB002/JSON002/JSON003/DATA002 diagnostic branches are skipped
entirely -- silently, exit 0, no trace. `mimir conform` uses the Virtual_Only
resolution policy (orchestrator/run.odin), which calls the proc exactly
once and was never affected -- which is why these fixtures always looked
"fine" under conform while being dark under CLI check.

Fix: init_virtual_registry now caches its first result on the Type_Registry
(reg.vreg_cache) and returns the cached Virtual_Registry unchanged on
re-entry -- one structural guard, not four per-field patches.

Covers (positive AND negative), both CLI check modes:
  - single-file project-mode check (cmd_check_single -> Full_Single):
    the exact path proven RED pre-fix / GREEN post-fix.
  - directory project-mode check (cmd_check_multi -> Full_Multi): the
    other project-mode call site sharing the same double-init mechanism.
  - negative direction: known-clean fixtures using the SAME virtual
    modules correctly must fire ZERO occurrences of the code (proves the
    cache fix introduces no false positive, doesn't just always-fire).

This test is expected to RED on the pre-fix binary (verified manually:
git stash the fix, rebuild, all four POSITIVE cases fail) and GREEN
post-fix -- both directions checked by hand before this file was added;
this script is what makes that proof permanent and repeatable.

Usage:
    python3 tests/scripts/registry_reinit_test.py [--mimir-bin ./mimir_bin]
"""

import argparse
import os
import subprocess
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# code -> (positive fixture [fires], negative fixture [must NOT fire], dir for directory-mode)
CASES = {
    "DB002": (
        "tests/conformance/db/db_injection.py",
        "tests/conformance/db/db_query_typed.py",
        "tests/conformance/db",
    ),
    "JSON002": (
        "tests/conformance/json/json_schema_errors.py",
        "tests/conformance/json/json_parse_typed.py",
        "tests/conformance/json",
    ),
    "JSON003": (
        "tests/conformance/json/json_schema_errors.py",
        "tests/conformance/json/json_parse_typed.py",
        "tests/conformance/json",
    ),
    "DATA002": (
        "tests/conformance/gap_data002.py",
        "tests/conformance/data/data_read_typed.py",
        None,  # gap_data002.py lives at conformance root; no small isolated dir to reuse
    ),
}


def run(mimir_bin: str, args, timeout=60):
    proc = subprocess.run(
        [mimir_bin] + args, capture_output=True, text=True, timeout=timeout, cwd=REPO_ROOT,
    )
    return proc.stdout + proc.stderr


def code_fires(output: str, code: str) -> bool:
    # Bracketed form only -- CLAUDE.md fixture-grep trap: bare greps can be
    # poisoned by filenames/docstrings containing the code string.
    return f"[{code}]" in output


def test_single_file_positive(mimir_bin: str) -> list:
    problems = []
    for code, (pos_fixture, _neg, _dir) in CASES.items():
        out = run(mimir_bin, ["check", pos_fixture])
        if not code_fires(out, code):
            problems.append(
                f"{code}: single-file project-mode check of {pos_fixture} did NOT "
                f"emit [{code}] -- registry-reinit regression:\n      {out.strip()!r}"
            )
    return problems


def test_single_file_negative(mimir_bin: str) -> list:
    problems = []
    for code, (_pos, neg_fixture, _dir) in CASES.items():
        out = run(mimir_bin, ["check", neg_fixture])
        if code_fires(out, code):
            problems.append(
                f"{code}: single-file project-mode check of KNOWN-CLEAN {neg_fixture} "
                f"emitted [{code}] -- false positive:\n      {out.strip()!r}"
            )
    return problems


def test_directory_mode_positive(mimir_bin: str) -> list:
    problems = []
    for code, (pos_fixture, _neg, dirpath) in CASES.items():
        if dirpath is None:
            continue
        out = run(mimir_bin, ["check", dirpath])
        if not code_fires(out, code):
            problems.append(
                f"{code}: directory project-mode check of {dirpath} did NOT emit "
                f"[{code}] (expected from {pos_fixture}) -- registry-reinit regression "
                f"in Full_Multi:\n      {out.strip()!r}"
            )
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
        ("single-file project-mode: DB002/JSON002/JSON003/DATA002 fire (positive)", test_single_file_positive),
        ("single-file project-mode: known-clean fixtures stay silent (negative)", test_single_file_negative),
        ("directory project-mode (Full_Multi): DB002/JSON002/JSON003 fire (positive)", test_directory_mode_positive),
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
    print(f"\nregistry_reinit: {total - failures}/{total} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
