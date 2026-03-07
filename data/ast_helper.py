"""
mimir AST helper — persistent subprocess that parses Python files via CPython's ast module.

Wire protocol (stdin/stdout):
  Request:  PARSE <path>\n
  Success:  OK <byte_length>\n<json_bytes>
  Error:    ERR <byte_length>\n<error_json>
  Shutdown: QUIT\n
"""

import ast
import json
import sys
import base64


def serialize(node):
    if isinstance(node, ast.AST):
        result = {"_t": type(node).__name__}
        for field, value in ast.iter_fields(node):
            result[field] = serialize(value)
        if hasattr(node, "lineno"):
            result["_loc"] = [
                node.lineno,
                node.col_offset,
                getattr(node, "end_lineno", None) or 0,
                getattr(node, "end_col_offset", None) or 0,
            ]
        return result
    elif isinstance(node, list):
        return [serialize(x) for x in node]
    elif isinstance(node, bytes):
        return {"_bytes": base64.b64encode(node).decode("ascii")}
    elif node is ...:
        return {"_ellipsis": True}
    elif isinstance(node, complex):
        return {"_complex": [node.real, node.imag]}
    elif isinstance(node, frozenset):
        return {"_frozenset": [serialize(x) for x in sorted(node, key=repr)]}
    elif isinstance(node, bool):
        return node
    elif isinstance(node, (int, float, str)):
        return node
    elif node is None:
        return None
    else:
        return repr(node)


def main():
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        if line == "QUIT":
            break

        parts = line.split(" ", 1)
        if len(parts) != 2 or parts[0] != "PARSE":
            err = json.dumps(
                {"error": "ProtocolError", "msg": "unknown command", "line": 0, "col": 0},
                ensure_ascii=True,
                separators=(",", ":"),
            )
            sys.stdout.write(f"ERR {len(err)}\n")
            sys.stdout.write(err)
            sys.stdout.flush()
            continue

        path = parts[1]
        try:
            with open(path, "r", encoding="utf-8") as f:
                source = f.read()
            try:
                tree = ast.parse(source, filename=path, type_comments=True)
            except SyntaxError:
                tree = ast.parse(source, filename=path)
            result = serialize(tree)
            data = json.dumps(result, ensure_ascii=True, separators=(",", ":"))
            sys.stdout.write(f"OK {len(data)}\n")
            sys.stdout.write(data)
            sys.stdout.flush()
        except SyntaxError as e:
            err = json.dumps(
                {
                    "error": "SyntaxError",
                    "msg": str(e.msg) if e.msg else str(e),
                    "line": e.lineno or 0,
                    "col": e.offset or 0,
                },
                ensure_ascii=True,
                separators=(",", ":"),
            )
            sys.stdout.write(f"ERR {len(err)}\n")
            sys.stdout.write(err)
            sys.stdout.flush()
        except Exception as e:
            err = json.dumps(
                {
                    "error": type(e).__name__,
                    "msg": str(e),
                    "line": 0,
                    "col": 0,
                },
                ensure_ascii=True,
                separators=(",", ":"),
            )
            sys.stdout.write(f"ERR {len(err)}\n")
            sys.stdout.write(err)
            sys.stdout.flush()


if __name__ == "__main__":
    main()
