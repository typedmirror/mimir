#!/usr/bin/env python3
"""
LSP smoke regression test (Phase T, track T4 step F).

Drives `mimir lsp` over JSON-RPC (Content-Length framing) exactly like an
editor: initialize -> initialized -> textDocument/didOpen(fixture) -> collect
the textDocument/publishDiagnostics notification. Asserts the published
diagnostic set (line, character, code, severity tuples + count) equals the
checked-in golden capture. Also reports didOpen/didChange re-analysis
wall-times so latency drift is visible at checkpoints.

The comparison is ORDER-INSENSITIVE (sorted tuples): within-pass emission
order of some diagnostics (e.g. D001) is Odin-map-layout dependent and can
permute across builds — a known, characterized non-semantic wobble. Codes,
positions, severities, and the count are the semantic payload and must be
exact.

Usage:
    python3 tests/scripts/lsp_smoke_test.py [--mimir-bin ./mimir_bin]
    python3 tests/scripts/lsp_smoke_test.py --capture   # (re)write golden

Fixture: tests/fixtures/lsp_smoke/sample.py
Golden:  tests/fixtures/lsp_smoke/expected_diagnostics.json
"""

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "fixtures", "lsp_smoke", "sample.py")
GOLDEN = os.path.join(HERE, "..", "fixtures", "lsp_smoke", "expected_diagnostics.json")


def frame(payload: dict) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    return b"Content-Length: %d\r\n\r\n%s" % (len(body), body)


class LspClient:
    def __init__(self, mimir_bin: str):
        self.proc = subprocess.Popen(
            [mimir_bin, "lsp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.buf = b""

    def send(self, payload: dict):
        self.proc.stdin.write(frame(payload))
        self.proc.stdin.flush()

    def read_message(self, timeout: float = 15.0) -> dict:
        """Read one Content-Length framed JSON message."""
        deadline = time.time() + timeout
        while True:
            # Try to parse a full message from the buffer
            header_end = self.buf.find(b"\r\n\r\n")
            if header_end >= 0:
                header = self.buf[:header_end].decode("utf-8", "replace")
                length = None
                for line in header.split("\r\n"):
                    if line.lower().startswith("content-length:"):
                        length = int(line.split(":", 1)[1].strip())
                if length is None:
                    raise RuntimeError("frame without Content-Length: %r" % header)
                body_start = header_end + 4
                if len(self.buf) >= body_start + length:
                    body = self.buf[body_start:body_start + length]
                    self.buf = self.buf[body_start + length:]
                    return json.loads(body)
            if time.time() > deadline:
                raise TimeoutError("no LSP message within %.1fs (buf=%r)" % (timeout, self.buf[:200]))
            chunk = self.proc.stdout.read1(65536)
            if not chunk:
                raise RuntimeError("LSP server closed stdout (exit=%s)" % self.proc.poll())
            self.buf += chunk

    def wait_for(self, method: str, timeout: float = 15.0) -> dict:
        """Read messages until a notification with `method` arrives."""
        deadline = time.time() + timeout
        while time.time() <= deadline:
            msg = self.read_message(timeout=max(0.1, deadline - time.time()))
            if msg.get("method") == method:
                return msg
        raise TimeoutError("did not receive %s" % method)

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def diag_tuples(diags: list) -> list:
    """Reduce published diagnostics to sorted (line, character, code, severity)."""
    out = []
    for d in diags:
        start = d.get("range", {}).get("start", {})
        out.append([
            start.get("line", -1),
            start.get("character", -1),
            d.get("code", ""),
            d.get("severity", -1),
        ])
    out.sort()
    return out


def run_session(mimir_bin: str, content: str):
    """Full editor session. Returns (tuples, count, open_ms, change_ms, raw)."""
    uri = "file:///lsp_smoke/sample.py"
    cli = LspClient(mimir_bin)
    try:
        cli.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        cli.read_message()  # initialize response
        cli.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

        t0 = time.time()
        cli.send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
            "textDocument": {"uri": uri, "languageId": "python", "version": 1,
                             "text": content}}})
        note = cli.wait_for("textDocument/publishDiagnostics")
        open_ms = (time.time() - t0) * 1000.0
        diags = note.get("params", {}).get("diagnostics", [])

        # Re-analysis latency probe: modified content (cache-busting comment)
        t1 = time.time()
        cli.send({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
            "textDocument": {"uri": uri, "version": 2},
            "contentChanges": [{"text": content + "\n# touch\n"}]}})
        cli.wait_for("textDocument/publishDiagnostics")
        change_ms = (time.time() - t1) * 1000.0

        return diag_tuples(diags), len(diags), open_ms, change_ms, diags
    finally:
        cli.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mimir-bin", default="./mimir_bin")
    ap.add_argument("--capture", action="store_true",
                    help="write the golden file from the current binary")
    args = ap.parse_args()

    with open(FIXTURE, "r", encoding="utf-8") as f:
        content = f.read()

    tuples, count, open_ms, change_ms, raw = run_session(args.mimir_bin, content)
    print("published diagnostics: %d" % count)
    print("didOpen->publish: %.1f ms | didChange->publish: %.1f ms" % (open_ms, change_ms))

    if args.capture:
        golden = {
            "count": count,
            "tuples": tuples,
            "raw_for_humans": raw,  # informational only — NOT asserted
        }
        with open(GOLDEN, "w", encoding="utf-8") as f:
            json.dump(golden, f, indent=1)
        print("golden written: %s" % os.path.relpath(GOLDEN))
        for t in tuples:
            print("  L%d:%d %s sev=%d" % (t[0] + 1, t[1], t[2], t[3]))
        return 0

    with open(GOLDEN, "r", encoding="utf-8") as f:
        golden = json.load(f)

    ok = True
    if count != golden["count"]:
        print("FAIL: count %d != golden %d" % (count, golden["count"]))
        ok = False
    if tuples != golden["tuples"]:
        print("FAIL: diagnostic tuples differ from golden")
        got = {tuple(t) for t in tuples}
        want = {tuple(t) for t in golden["tuples"]}
        for t in sorted(want - got):
            print("  missing: L%d:%d %s sev=%d" % (t[0] + 1, t[1], t[2], t[3]))
        for t in sorted(got - want):
            print("  extra:   L%d:%d %s sev=%d" % (t[0] + 1, t[1], t[2], t[3]))
        ok = False

    print("lsp_smoke: %s (%d diagnostics)" % ("PASS" if ok else "FAIL", count))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
