#!/usr/bin/env python3
"""
Every-code-fires gate (Phase T, track T3a).

Answers one question: which diagnostic codes that mimir can emit NEVER fire
across the test corpus (conformance + smoke)? A rule that exists but is never
exercised by any test is an unmeasured instrument — this gate makes that set
loud and forces a per-code justification (waiver) for every silent code.

INVENTORY METHOD (grep-based, two documented counting rules)
------------------------------------------------------------
Scan every src/**/*.odin line for quoted code-shaped literals
("[A-Z]{1,8}[0-9]{2,4}", e.g. "T001", "SEC010"). Classify each occurrence:

  EMISSION SITE (makes the code emittable):
    1. named-field construction:  code = "X"
       (Diagnostic literals and rule tables; src/platform/explain.odin is
       EXCLUDED — its 116 `code = "..."` entries are documentation DB rows
       for `mimir explain`, not emissions)
    2. positional emit-helper call on the same line:
       emit( / emit_diagnostic( / emit_diagnostic_raw( /
       add_gpu_diagnostic[_severity]( / add_wasm_diagnostic[_severity](
       (helper list verified against every `code = code` passthrough
       Diagnostic constructor in src/ as of 2026-07-15)

  NON-EMISSION (never makes a code emittable):
    explain-DB row, // comment, `case` list (e.g. resolve_confidence),
    == comparison, rule-enable/level check, anything else.

A code is EMITTABLE iff it has at least one emission-site occurrence.

INVENTORY BRIDGE (Amendment 2 — no silent number)
-------------------------------------------------
Two counting methods exist for this codebase and they must reconcile:
  * naive `code = "X"` grep over all of src/  -> 159 distinct codes
    (this number OVERCOUNTS via explain.odin doc rows and UNDERCOUNTS
    positional emit-helper literals)
  * this script's emission-site classification -> printed below at run time
    (named-field outside explain.odin, UNION positional emit literals);
    measured 165 as of 2026-07-15, vs the instrument-audit figure of 166.
    The one-code delta is DATA003: it exists ONLY as an explain-DB doc row
    (src/platform/explain.odin:577) with zero emission sites in src/ — a
    count that treats explain rows as emissions reaches 166; this gate does
    not, because `mimir explain` documents codes, it does not emit them.
The script prints every excluded code with the contexts it appears in, so
both numbers and the delta are itemized on every run — never one bare count.

CORPUS RUN
----------
Runs `mimir check/lint/audit/perf/safety` (the five analysis commands) over
tests/conformance/ and tests/smoke/, then parses fired codes from diagnostic
lines (`file:line:col: severity[CODE]: ...`, tolerating `[CODE|confidence]`).

`check` runs BOTH per-directory (project/multi-file mode — reaches module
graph codes) AND once per .py file (single-file mode — reaches domain
checkers that directory mode does not; measured 2026-07-15: CONC003/CONC005
fire per-file but not per-directory). lint/audit/perf/safety run
per-directory only: their directory mode is an in-process per-file loop, so
per-file invocation adds nothing.

Codes reachable only through other commands (migrate, lsp, compile-gpu, ...)
will be silent here and need a waiver naming that command.

CRASH REPORTING: any invocation killed by a signal (segfault etc.) is listed
loudly in the output — a crashed run is UNMEASURED, and codes expected from
it may be wrongly counted silent. Crashes do not flip the exit code (fixing
checker crashes is outside this gate's scope; T-phase triage owns them), but
they are never hidden, and waivers for affected codes must name the crash.

WAIVERS
-------
tests/scripts/silent_code_waivers.txt — one `CODE  justification` per line
('#' starts a comment). Every silent code must be waived with a non-empty
justification or the gate exits 1. A waiver for a code that is not in the
emittable inventory is an error (typo or removed rule — clean it up). A
waiver for a code that now FIRES is reported as STALE (warning, exit 0:
coverage improved; remove the line).

Exit codes: 0 = all silent codes waived; 1 = unwaived silent codes or bad
waiver file; 2 = environment/setup failure.

Usage:
    python3 tests/scripts/every_code_fires.py [--mimir-bin PATH]
        [--waivers PATH] [--verbose]
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

CODE_LITERAL = re.compile(r'"([A-Z]{1,8}[0-9]{2,4})"')
FIELD_ASSIGN = re.compile(r'\bcode\s*=\s*"([A-Z]{1,8}[0-9]{2,4})"')
EMIT_CALL = re.compile(
    r'\b(?:emit|emit_diagnostic|emit_diagnostic_raw'
    r'|add_gpu_diagnostic(?:_severity)?|add_wasm_diagnostic(?:_severity)?)\('
)
ENABLE_CHECK = re.compile(r'\bis_\w*rule_enabled\b|\bshould_emit_at_level\b')
FIRED = re.compile(r'\[([A-Z]{1,8}[0-9]{2,4})(?:\|[a-z]+)?\]:')

COMMANDS = ["check", "lint", "audit", "perf", "safety"]
CORPUS = ["tests/conformance", "tests/smoke"]
EXPLAIN_DB = Path("src") / "platform" / "explain.odin"


def build_inventory(verbose: bool):
    """Scan src/ and classify every code-shaped literal occurrence.

    Returns (emittable: dict code -> set of emission kinds,
             excluded:  dict code -> set of non-emission contexts,
             stats:     dict of bridge numbers).
    """
    emission = {}   # code -> set(kind)
    contexts = {}   # code -> set(context) for ALL occurrences
    naive_field = set()  # naive `code = "X"` grep INCLUDING explain.odin

    src = ROOT / "src"
    for path in sorted(src.rglob("*.odin")):
        rel = path.relative_to(ROOT)
        is_explain = rel == EXPLAIN_DB
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as e:
            print(f"error: cannot read {rel}: {e}", file=sys.stderr)
            sys.exit(2)
        for lineno, line in enumerate(lines, 1):
            lits = list(CODE_LITERAL.finditer(line))
            if not lits:
                continue
            comment_at = line.find("//")
            field_spans = [
                (m.start(1), m.end(1), m.group(1)) for m in FIELD_ASSIGN.finditer(line)
            ]
            emit_call = EMIT_CALL.search(line)
            for m in lits:
                code = m.group(1)
                # naive grep bookkeeping (bridge number)
                if any(s <= m.start(1) and m.end(1) <= e for s, e, c in field_spans):
                    naive_field.add(code)
                # classify this occurrence
                if comment_at != -1 and m.start() > comment_at:
                    ctx = "comment"
                elif is_explain:
                    ctx = "explain-DB"
                elif any(s <= m.start(1) and m.end(1) <= e for s, e, c in field_spans):
                    ctx = "EMIT:field-assign"
                elif emit_call and emit_call.start() < m.start():
                    ctx = "EMIT:emit-helper"
                elif "case " in line:
                    ctx = "case-list"
                elif "==" in line:
                    ctx = "comparison"
                elif ENABLE_CHECK.search(line):
                    ctx = "enable-check"
                else:
                    ctx = "other"
                contexts.setdefault(code, set()).add(ctx)
                if ctx.startswith("EMIT:"):
                    emission.setdefault(code, set()).add(ctx[5:])
                    if verbose:
                        print(f"  emission: {code:10s} {rel}:{lineno} ({ctx[5:]})")

    excluded = {
        code: ctxs for code, ctxs in contexts.items() if code not in emission
    }
    field_outside_explain = {
        c for c, kinds in emission.items() if "field-assign" in kinds
    }
    helper_only = {
        c for c, kinds in emission.items() if kinds == {"emit-helper"}
    }
    stats = {
        "distinct_literals": len(contexts),
        "naive_field_grep": len(naive_field),
        "field_outside_explain": len(field_outside_explain),
        "helper_only": len(helper_only),
        "emittable": len(emission),
        "excluded": len(excluded),
    }
    return emission, excluded, stats


def _run_one(mimir_bin: str, cmd: str, target: str, fired: dict, crashes: list, verbose: bool):
    argv = [mimir_bin, cmd, target]
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=600, cwd=ROOT
        )
    except subprocess.TimeoutExpired:
        print(f"error: timed out: {' '.join(argv)}", file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        print(f"error: cannot run {' '.join(argv)}: {e}", file=sys.stderr)
        sys.exit(2)
    output = proc.stdout + "\n" + proc.stderr
    codes = set(FIRED.findall(output))
    for code in codes:
        fired.setdefault(code, set()).add(f"{cmd} {target}")
    if proc.returncode < 0:
        # Killed by a signal (e.g. -11 = SIGSEGV). The run is UNMEASURED for
        # this target: codes that would fire here are invisible. Report loud.
        crashes.append(f"mimir {cmd} {target} (signal {-proc.returncode})")
    if verbose:
        print(f"  ran: mimir {cmd} {target} -> {len(codes)} distinct codes")


def run_corpus(mimir_bin: str, verbose: bool):
    """Run the five analysis commands over the corpus; return fired codes
    and the list of invocations killed by a signal (crashes)."""
    fired = {}  # code -> set of "command target" that emitted it
    crashes = []
    for target in CORPUS:
        if not (ROOT / target).is_dir():
            print(f"error: corpus directory missing: {target}", file=sys.stderr)
            sys.exit(2)
    for cmd in COMMANDS:
        for target in CORPUS:
            _run_one(mimir_bin, cmd, target, fired, crashes, verbose)
    # Single-file check pass: directory-mode `check` uses the multi-file
    # pipeline, which reaches fewer domain checkers than single-file mode
    # (measured 2026-07-15: CONC003/CONC005 fire per-file only).
    n_files = 0
    for target in CORPUS:
        for py in sorted((ROOT / target).rglob("*.py")):
            _run_one(mimir_bin, "check", str(py.relative_to(ROOT)), fired, crashes, False)
            n_files += 1
    if verbose:
        print(f"  ran: mimir check per-file over {n_files} corpus files")
    return fired, crashes


def load_waivers(path: Path):
    """Parse the waiver file. Returns (dict code -> justification, errors)."""
    waivers = {}
    errors = []
    if not path.exists():
        return waivers, errors
    for lineno, raw in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        code = parts[0]
        just = parts[1].strip() if len(parts) > 1 else ""
        if not re.fullmatch(r"[A-Z]{1,8}[0-9]{2,4}", code):
            errors.append(f"{path.name}:{lineno}: not a valid code: '{code}'")
            continue
        if not just:
            errors.append(
                f"{path.name}:{lineno}: waiver for {code} has no justification"
            )
            continue
        if code in waivers:
            errors.append(f"{path.name}:{lineno}: duplicate waiver for {code}")
            continue
        waivers[code] = just
    return waivers, errors


def main():
    ap = argparse.ArgumentParser(description="Every-code-fires gate")
    ap.add_argument("--mimir-bin", default=str(ROOT / "mimir_bin"))
    ap.add_argument(
        "--waivers", default=str(ROOT / "tests" / "scripts" / "silent_code_waivers.txt")
    )
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.mimir_bin):
        print(
            f"error: mimir binary not found at {args.mimir_bin} "
            "(build with: odin build src/ -collection:mimir=src/ -out:mimir "
            "-o:speed && cp mimir mimir_bin)",
            file=sys.stderr,
        )
        sys.exit(2)

    print("== inventory (see docstring for the two counting rules) ==")
    emission, excluded, stats = build_inventory(args.verbose)
    print(f"distinct code-shaped literals in src/:        {stats['distinct_literals']}")
    print(f"naive `code = \"X\"` grep (incl. explain.odin): {stats['naive_field_grep']}")
    print(f"  named-field emission sites (excl. explain): {stats['field_outside_explain']}")
    print(f"  emitted ONLY via positional emit helpers:   {stats['helper_only']}")
    print(f"EMITTABLE (union of both emission kinds):     {stats['emittable']}")
    print(f"excluded, no emission site ({stats['excluded']}):")
    for code in sorted(excluded):
        print(f"  {code:10s} appears only as: {', '.join(sorted(excluded[code]))}")

    print()
    print(f"== corpus run: {'/'.join(COMMANDS)} over {' + '.join(CORPUS)} ==")
    fired, crashes = run_corpus(args.mimir_bin, args.verbose)
    if crashes:
        print(f"CRASHED INVOCATIONS ({len(crashes)}) — these runs are UNMEASURED,")
        print("codes expected from them may be wrongly counted silent:")
        for c in crashes:
            print(f"  {c}")
    fired_emittable = {c for c in fired if c in emission}
    unknown_fired = {c for c in fired if c not in emission}
    silent = sorted(set(emission) - set(fired))
    print(f"fired: {len(fired_emittable)}/{stats['emittable']} emittable codes")
    if unknown_fired:
        # A fired code missing from the inventory means the inventory grep
        # has a blind spot — that is a gate failure, not a curiosity.
        print(f"FIRED BUT NOT IN INVENTORY ({len(unknown_fired)}): "
              f"{', '.join(sorted(unknown_fired))}")
    print(f"silent: {len(silent)} codes never fired across the corpus:")
    for code in silent:
        print(f"  {code}")

    print()
    print(f"== waivers ({args.waivers}) ==")
    waivers, waiver_errors = load_waivers(Path(args.waivers))
    for e in waiver_errors:
        print(f"waiver error: {e}")
    unknown_waivers = sorted(set(waivers) - set(emission))
    for code in unknown_waivers:
        print(f"waiver error: {code} is not an emittable code (typo or removed rule)")
    stale = sorted(set(waivers) & set(fired))
    for code in stale:
        print(f"STALE waiver (code now fires — remove the line): {code}")
    unwaived = [c for c in silent if c not in waivers]
    waived = [c for c in silent if c in waivers]
    print(f"waived silent codes: {len(waived)}")
    if args.verbose:
        for code in waived:
            print(f"  {code:10s} {waivers[code]}")

    print()
    ok = not unwaived and not waiver_errors and not unknown_waivers and not unknown_fired
    if unwaived:
        print(f"UNWAIVED SILENT CODES ({len(unwaived)}):")
        for code in unwaived:
            kinds = ", ".join(sorted(emission[code]))
            print(f"  {code:10s} (emission: {kinds}) — add a fixture or a justified waiver")
    if ok:
        print("gate: PASS — every emittable code fires or carries a justified waiver")
        sys.exit(0)
    print("gate: FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
