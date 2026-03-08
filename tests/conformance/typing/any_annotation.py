# Any annotation conformance — no errors expected

from typing import Any

def accepts_any(x: Any) -> None:
    pass

x: Any = 42
y: Any = "hello"
accepts_any(x)
accepts_any(y)

# Any is compatible with everything
n: int = 1
accepts_any(n)
