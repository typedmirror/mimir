# T2 regression: `from __future__ import annotations` binds the name
# `annotations` — a compiler directive (PEP 236), never "unused" (L001 FP).
# The genuinely unused import below must still fire.
from __future__ import annotations
import json  # E


def f(x: int) -> str:
    return str(x)
