"""T1 regression: package-relative import in single-file mode (no package
context) → B003 relative flavor + summary on the SUCCESS exit path."""
from .sib import helper


def fine() -> int:
    return 1
