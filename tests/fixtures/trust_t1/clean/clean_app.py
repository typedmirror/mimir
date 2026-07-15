"""T1 regression (negative/FP guard): everything resolves, nothing dropped —
NO B003, NO P001, NO summary line, zero errors."""
import os
from helper import double, Box


def run() -> str:
    b = Box("x")
    n = double(21)
    return f"{os.sep}{b.label}{n}"
