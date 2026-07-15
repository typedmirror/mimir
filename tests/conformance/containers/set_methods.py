from typing import assert_type

s: set[int] = {1, 2, 3}

# Correct
assert_type(s.pop(), int)
good1: set[int] = s.copy()

# Errors
bad1: str = s.pop()  # E[T001]
bad2: int = s.add(4)  # E[T001]
bad3: str = s.copy()  # E[T001]
assert_type(s.pop(), str)  # E[T006]
bad4: int = s.union({4, 5})  # E[T001]
