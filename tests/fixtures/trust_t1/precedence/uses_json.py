"""T1 regression: local sibling SHADOWS stdlib (mypy/sys.path[0] parity).
The T001 below only fires if the sibling json.py won — stdlib json has no
Widget, so losing precedence degrades Widget to Unknown and hides the bug."""
from json import Widget


def label_len() -> None:
    w = Widget("a")
    x: int = w.name  # T001: str assigned to int — proves sibling types flowed
    print(x)
