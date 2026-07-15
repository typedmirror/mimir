#!/usr/bin/env python3
"""
migrate_markers.py -- Phase T, track T3b.

Migrate the bare conformance markers (# E, # E: text) under tests/conformance/
to code-specific form (# E[CODE], or # E[C1|C2] alternation) by OBSERVING
which diagnostic code(s) actually fire on each marked line. It drives
./mimir_bin exactly as the conform runner's per-prefix stages do
(src/conform/runner.odin) and parses `file:line:col: severity[CODE]:` output.

The migration TIGHTENS the instrument: a bare `# E` matches any error on the
line, so a wrong-code regression slips through; `# E[CODE]` fails unless that
exact code fires. The script never invents a code -- it only asserts what the
live binary emits -- so a green suite after migration means every code marker
was true at migration time.

IDEMPOTENT & RE-RUNNABLE. It re-derives codes for every required marker (bare
OR already-migrated `# E[..]`) from live output, so it performs the initial
migration and also MAINTAINS the markers as the checker evolves. Running it
twice with no checker change is a no-op.

SCOPE
-----
tests/conformance/ ONLY. It deliberately EXCLUDES:
  * tests/conform_selftest/  -- the T3a proof harness. Its fixtures contain
    intentionally WRONG codes (wrong_code.py) and MALFORMED markers
    (malformed_*.py); rewriting them would destroy the proof.
  * tests/fixtures/          -- trust fixtures (trust_t1/*) driven by
    t1_trust_test.py, not by `mimir conform`.
These live outside tests/conformance, so the default root already excludes
them; the exclusion is also enforced defensively for any explicit root.

STAGE MODEL (mirrors src/conform/runner.odin exactly)
-----------------------------------------------------
For every file, ALWAYS:
    mimir check FILE
      record a line's code iff  severity == 'error'   (bind/flow/check are
      recorded Error-only by the runner)  OR  code starts with 'CONC'
      (concurrency is recorded at ALL severities, and CONC003/004/006 are
      warnings).
Additional passes, gated by filename prefix, recorded at ALL severities
(exactly the runner's gating):
    lint_*                    -> mimir lint  FILE   (L / C / S codes)
    sec_*  | taint_*          -> mimir audit FILE   (SEC codes)
    perf_*                    -> mimir perf  FILE   (PERF codes)
    safety_*  |  .../safety/  -> mimir safety FILE  (SAF codes)
A diagnostic with no [CODE] (e.g. a parse failure, printed on line 1 with no
bracket) yields an error line but no code, so a marker there cannot be
code-asserted -- see policy (c).

POLICY (proposed at T3b checkpoint 1)
-------------------------------------
(a) MULTIPLE codes on one line -> alternation of ALL fired codes, sorted:
    `# E[C1|C2|...]`. Faithful to observed behavior (a bare marker states no
    single intended code), order-independent (checker emission order does not
    make it flap), and still strictly tighter than bare (restricts to the
    observed set). Exactly one code -> `# E[CODE]`.
(b) `# E?` OPTIONAL markers are left UNCHANGED: the runner parses but never
    ENFORCES codes on optional markers (the optional-hit path ignores codes),
    so a code there buys no tightening and only risks a malformed-marker fail.
    `# E: text` INFORMATIONAL markers are REQUIRED markers counted in the 630,
    so they ARE migrated to `# E[CODE]: text`, preserving the text.
(c) A required marker line with NO capturable code is left BARE and reported in
    the FLAGGED list. The script never guesses. Bare markers keep exact legacy
    semantics, so a flagged line still passes conform.
(d) selftest + fixtures excluded (see SCOPE).

USAGE
-----
    python3 tests/scripts/migrate_markers.py            # dry run, prints plan
    python3 tests/scripts/migrate_markers.py --apply    # rewrite files
    python3 tests/scripts/migrate_markers.py --apply --files a.py b.py
    python3 tests/scripts/migrate_markers.py --report-flagged
Options: --root DIR (default tests/conformance), --mimir-bin PATH
(default ./mimir_bin), --verbose.

Exit 0 on success; 2 on environment/setup failure.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# `file:line:col: severity[CODE]:` -- tolerate a `|confidence` suffix in the
# bracket (some diagnostics carry a confidence tier).
DIAG = re.compile(
    r"^(?P<path>.*?):(?P<line>\d+):(?P<col>\d+):\s+"
    r"(?P<sev>[a-z]+)\[(?P<code>[A-Z]{1,8}[0-9]{2,4})(?:\|[a-z]+)?\]:"
)

# Excluded subtrees (defensive; they are outside tests/conformance anyway).
EXCLUDE_PARTS = ("conform_selftest", "fixtures")


def find_marker(line):
    """Mirror parse_markers in src/conform/markers.odin: the rightmost `# E`
    whose preceding char is whitespace or start-of-line. Returns (idx, rest)
    where rest is everything after `# E`, or None if the line has no marker."""
    idx = line.rfind("# E")
    if idx < 0:
        return None
    if idx > 0 and line[idx - 1] not in (" ", "\t"):
        return None
    return idx, line[idx + 3:]


def marker_kind(rest):
    """Classify the marker by the byte immediately after `# E`, matching the
    Odin grammar. Returns one of: 'bare', 'bracket', 'optional', 'text',
    'trailing', or None (not a marker)."""
    if rest == "":
        return "bare"
    c = rest[0]
    if c == "[":
        return "bracket"      # already code-specific (idempotent re-derive)
    if c == "?":
        return "optional"     # # E? (optionally # E?[CODE]) -- left unchanged
    if c == ":":
        return "text"         # # E: informational text
    if c == " ":
        return "trailing"     # # E <trailing commentary> (bare, legacy)
    return None               # # ERROR, # Example, ... -- not a marker


def marker_tail(rest, kind):
    """The bytes to preserve AFTER the inserted `[CODES]`. For a bracket marker
    it is whatever follows the old `]`; otherwise it is the whole `rest` (which
    already begins with the separator: '' / ': text' / ' commentary')."""
    if kind == "bracket":
        close = rest.find("]")
        if close < 0:
            return None       # unclosed bracket -- malformed; do not touch
        return rest[close + 1:]
    return rest               # '', ': text', ' commentary'


def run_mimir(mimir_bin, cmd, file, cache):
    key = (cmd, file)
    if key in cache:
        return cache[key]
    try:
        proc = subprocess.run(
            [mimir_bin, cmd, file],
            capture_output=True, text=True, timeout=120, cwd=ROOT,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"error: running `mimir {cmd} {file}`: {e}", file=sys.stderr)
        sys.exit(2)
    out = proc.stdout + "\n" + proc.stderr
    cache[key] = out
    return out


def parse_diags(output):
    """Yield (line:int, severity:str, code:str) for every diagnostic line."""
    for raw in output.splitlines():
        m = DIAG.match(raw)
        if m:
            yield int(m.group("line")), m.group("sev"), m.group("code")


def derive_line_codes(mimir_bin, file, cache):
    """Return dict[int, set[str]] of codes the CONFORM RUNNER would record per
    line, reconstructed from CLI output under the runner's per-stage severity
    and prefix-gating rules."""
    rel = str(Path(file).relative_to(ROOT)) if os.path.isabs(file) else file
    base = os.path.basename(rel)
    lines = {}

    def add(ln, code):
        lines.setdefault(ln, set()).add(code)

    # Always-on: check (bind/flow/check Error-only; concurrency all-severity).
    for ln, sev, code in parse_diags(run_mimir(mimir_bin, "check", rel, cache)):
        if sev == "error" or code.startswith("CONC"):
            add(ln, code)

    # Prefix-gated analysis passes, recorded at all severities.
    gated = []
    if base.startswith("lint_"):
        gated.append("lint")
    if base.startswith("sec_") or base.startswith("taint_"):
        gated.append("audit")
    if base.startswith("perf_"):
        gated.append("perf")
    if base.startswith("safety_") or "/safety/" in ("/" + rel.replace(os.sep, "/")):
        gated.append("safety")
    for cmd in gated:
        for ln, _sev, code in parse_diags(run_mimir(mimir_bin, cmd, rel, cache)):
            add(ln, code)

    return lines


def codes_to_marker(codes):
    """Render the [CODES] payload: single code or sorted alternation."""
    ordered = sorted(codes)
    return ordered[0] if len(ordered) == 1 else "|".join(ordered)


def migrate_file(mimir_bin, file, cache, apply, verbose):
    """Rewrite required markers in `file`. Returns a stats dict and (if apply)
    writes the file. Never downgrades a marker; leaves 0-code markers bare."""
    rel = str(Path(file).relative_to(ROOT)) if os.path.isabs(file) else file
    text = Path(ROOT / rel).read_text()
    line_codes = derive_line_codes(mimir_bin, rel, cache)

    src_lines = text.split("\n")
    stats = {"single": 0, "alt": 0, "optional": 0, "flagged": [], "changed": 0}

    for i, line in enumerate(src_lines):
        lineno = i + 1
        m = find_marker(line)
        if not m:
            continue
        idx, rest = m
        kind = marker_kind(rest)
        if kind is None:
            continue
        if kind == "optional":
            stats["optional"] += 1
            continue

        codes = line_codes.get(lineno, set())
        if not codes:
            # policy (c): no capturable code -> leave bare, flag it.
            reason = "parse-error/code-less diagnostic" if lineno == 1 else \
                     "no code fired on line (stage mismatch or code-less diag)"
            stats["flagged"].append((lineno, kind, reason))
            continue

        tail = marker_tail(rest, kind)
        if tail is None:
            stats["flagged"].append((lineno, kind, "malformed existing marker"))
            continue

        payload = codes_to_marker(codes)
        new_line = line[:idx] + "# E[" + payload + "]" + tail
        if "|" in payload:
            stats["alt"] += 1
        else:
            stats["single"] += 1
        if new_line != line:
            stats["changed"] += 1
            src_lines[i] = new_line
        if verbose and new_line != line:
            print(f"    L{lineno}: {line.strip()}  ->  {new_line.strip()}")

    if apply and stats["changed"]:
        Path(ROOT / rel).write_text("\n".join(src_lines))
    return stats


def discover(root):
    base = Path(root)
    if not base.is_absolute():
        base = ROOT / base
    files = []
    for p in sorted(base.rglob("*.py")):
        rel = p.relative_to(ROOT)
        if any(part in EXCLUDE_PARTS for part in rel.parts):
            continue
        files.append(str(rel))
    return files


def main():
    ap = argparse.ArgumentParser(description="Migrate conformance markers to code-specific form")
    ap.add_argument("--root", default="tests/conformance")
    ap.add_argument("--mimir-bin", default=str(ROOT / "mimir_bin"))
    ap.add_argument("--apply", action="store_true", help="write changes (default: dry run)")
    ap.add_argument("--files", nargs="*", help="restrict to these files (paths relative to repo root)")
    ap.add_argument("--report-flagged", action="store_true", help="print every flagged (left-bare) marker")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.mimir_bin):
        print(f"error: mimir binary not found at {args.mimir_bin} "
              "(build: odin build src/ -collection:mimir=src/ -out:mimir -o:speed && cp mimir mimir_bin)",
              file=sys.stderr)
        sys.exit(2)

    files = args.files if args.files else discover(args.root)
    if not files:
        print(f"error: no .py files under {args.root}", file=sys.stderr)
        sys.exit(2)

    cache = {}
    tot = {"single": 0, "alt": 0, "optional": 0, "changed": 0}
    flagged_all = []
    for f in files:
        st = migrate_file(args.mimir_bin, f, cache, args.apply, args.verbose)
        for k in ("single", "alt", "optional", "changed"):
            tot[k] += st[k]
        for (ln, kind, reason) in st["flagged"]:
            flagged_all.append((f, ln, kind, reason))
        if args.verbose and (st["single"] or st["alt"] or st["flagged"]):
            print(f"  {f}: single={st['single']} alt={st['alt']} flagged={len(st['flagged'])}")

    mode = "APPLIED" if args.apply else "DRY RUN (no files written; pass --apply to write)"
    print(f"\n== migrate_markers: {mode} ==")
    print(f"files scanned:              {len(files)}")
    print(f"single-code migrations:     {tot['single']}")
    print(f"alternation migrations:     {tot['alt']}")
    print(f"required markers migratable: {tot['single'] + tot['alt']}")
    print(f"optional (# E?) left as-is:  {tot['optional']}")
    print(f"flagged (left bare, no code): {len(flagged_all)}")
    if args.apply:
        print(f"lines actually rewritten:   {tot['changed']}")
    if flagged_all and (args.report_flagged or not args.apply):
        print("\nFLAGGED markers (left bare -- no code captured; never guessed):")
        for (f, ln, kind, reason) in flagged_all:
            print(f"  {f}:{ln} ({kind}) -- {reason}")
    sys.exit(0)


if __name__ == "__main__":
    main()
