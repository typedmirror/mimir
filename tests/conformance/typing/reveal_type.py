# reveal_type conformance — no errors expected

# reveal_type is a Python 3.11+ builtin (no import needed)
x: int = 42
reveal_type(x)

# With import and alias
from typing import reveal_type as rt
y: str = "hello"
rt(y)
