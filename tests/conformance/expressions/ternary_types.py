from typing import assert_type

# Ternary with same types
x = 1 if True else 2
assert_type(x, int)

# Ternary with different types
y = "hi" if True else 42

# Ternary in assignment context
z: str = "yes" if True else "no"
assert_type(z, str)

# Ternary type mismatch with annotation
bad: int = "yes" if True else "no"  # E
