from typing import assert_type

# String + int not allowed
x = "hello" + 42  # E

# List subtraction not allowed
y = [1, 2] - [3]  # E

# Bitwise on float not allowed
z = 3.14 & 1  # E
