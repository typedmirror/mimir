from typing import assert_type, Optional

# Narrowed variable can be reassigned with same type
x: Optional[int] = 42
if x is not None:
    assert_type(x, int)
    x = x + 1
    assert_type(x, int)
