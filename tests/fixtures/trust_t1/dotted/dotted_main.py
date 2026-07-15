"""T1 regression: dotted module resolves against the file's own directory
(mypkg/util.py, namespace style). Misuse proves the types actually flowed."""
from mypkg.util import helper


def go() -> None:
    n: int = helper(True)  # T001: str assigned to int — proves resolution
    print(n)
