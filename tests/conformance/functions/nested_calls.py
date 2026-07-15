from typing import assert_type

# Correct: nested call type propagation
assert_type(len(str(42)), int)

# Errors
bad1: str = len("hello")  # E[T001]
bad2: int = str(42)  # E[T001]
bad3: bool = int("42")  # E[T001]
