from typing import assert_type

# String + int not allowed
x = "hello" + 42  # E[T005]

# List subtraction not allowed
y = [1, 2] - [3]  # E[T005]

# Bitwise on float not allowed
z = 3.14 & 1  # E[T005]
