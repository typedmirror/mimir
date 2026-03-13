from typing import assert_type, Callable

# Lambda with Callable annotation
f: Callable[[int], int] = lambda x: x + 1

# Lambda in higher-order function
names = ["charlie", "alice", "bob"]
sorted_names = sorted(names, key=lambda s: len(s))
assert_type(sorted_names, list[str])

# Lambda with multiple args
add: Callable[[int, int], int] = lambda x, y: x + y
