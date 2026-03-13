from typing import assert_type

# Try/except basic flow
try:
    x = int("123")
    assert_type(x, int)
except ValueError:
    pass

# Multiple exception types
try:
    y = 1 / 0
except (ZeroDivisionError, ValueError):
    pass

# Try/except/else/finally
try:
    z = 42
except Exception:
    z = 0
else:
    z = z + 1
finally:
    pass
