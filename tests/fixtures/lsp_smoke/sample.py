"""LSP smoke fixture — planted diagnostics across multiple analysis passes.

Used by tests/scripts/lsp_smoke_test.py to assert that `mimir lsp` publishes
an identical diagnostic set before/after orchestration changes (T4 step F).
Do not edit without re-capturing expected_diagnostics.json (--capture).
"""
import hashlib
import os


def get_data() -> str:
    return "text"


def process(count: int) -> int:
    return count * 2


x: int = get_data()      # T001: str assigned to int annotation
y = process("five")      # T002: str argument for int parameter


def leftover() -> None:
    unused_var = 42      # D001: assigned but never used
    return None


h = hashlib.md5(b"data")  # SEC001: weak hash algorithm

cmd = "ls -la"
os.system(cmd)            # dangerous call pattern

try:
    n = int("7")
except:                   # bare except (lint/safety)
    pass
