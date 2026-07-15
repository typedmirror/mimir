from typing import assert_type

# Correct: builtin return types
assert_type(len("hello"), int)
assert_type(input(), str)
assert_type(repr(42), str)
assert_type(hash("x"), int)
assert_type(id(42), int)
assert_type(sum([1, 2]), int)

# Errors
bad1: str = len("hello")  # E[T001]
bad2: int = input()  # E[T001]
