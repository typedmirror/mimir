from typing import assert_type

# Complex literal type
z = 1 + 2j
assert_type(z, complex)

z2 = 3.14j
assert_type(z2, complex)

# Complex assignment
c: complex = 1j
assert_type(c, complex)

# Wrong type
bad: int = 1j  # E[T001]
