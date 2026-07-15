# T2 regression: F002 must NOT fire when a try/with structure returns on every
# real path (the FP class), and MUST still fire when a path genuinely leaks.
from typing import Optional, List


def all_paths_return(path: str) -> Optional[List[str]]:
    try:
        with open(path, "r") as f:
            return f.readlines()
    except (FileNotFoundError, PermissionError):
        return None


def nested_ok(path: str) -> Optional[str]:
    try:
        with open(path) as f:
            with open(path) as g:
                return f.read() + g.read()
    except OSError:
        return None


def leaky(path: str) -> Optional[str]:  # E
    try:
        with open(path) as fh:
            x = fh.read()
            print(x)
    except OSError:
        return None
