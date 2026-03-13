from typing import Callable, assert_type

# Lambda matches Callable signature
f1: Callable[[int], str] = lambda x: str(x)
assert_type(f1, Callable[[int], str])

# Lambda with wrong param count
f2: Callable[[int, str], bool] = lambda x: True  # E
