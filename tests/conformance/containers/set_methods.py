from typing import assert_type

s: set[int] = {1, 2, 3}

# Correct
assert_type(s.pop(), int)
good1: set[int] = s.copy()

# Errors
bad1: str = s.pop()  # E
bad2: int = s.add(4)  # E
bad3: str = s.copy()  # E
assert_type(s.pop(), str)  # E
bad4: int = s.union({4, 5})  # E
