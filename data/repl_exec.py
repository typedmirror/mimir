"""Persistent execution wrapper for mimir REPL.

Reads code blocks from stdin (delimited by \x00__MIMIR_EXEC__\x00 sentinel),
executes them in a persistent namespace, and writes \x00__MIMIR_DONE__\x00
after each block completes. This avoids re-executing previous code.
"""
import sys, traceback

_ns = {"__name__": "__main__", "__builtins__": __builtins__}

while True:
    code = ""
    while True:
        line = sys.stdin.readline()
        if not line:
            sys.exit(0)
        if line.rstrip("\n") == "\x00__MIMIR_EXEC__\x00":
            break
        code += line
    if not code.strip():
        sys.stdout.write("\x00__MIMIR_DONE__\x00\n")
        sys.stdout.flush()
        continue
    try:
        try:
            result = eval(compile(code.strip(), "<repl>", "eval"), _ns)
            if result is not None:
                print(repr(result))
        except SyntaxError:
            exec(compile(code, "<repl>", "exec"), _ns)
    except SystemExit:
        pass
    except Exception:
        traceback.print_exc(file=sys.stdout)
    sys.stdout.write("\x00__MIMIR_DONE__\x00\n")
    sys.stdout.flush()
