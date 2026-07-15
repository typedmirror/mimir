from typing import assert_type

d: dict[str, int] = {"a": 1}

# Correct
assert_type(d.get("a"), int)  # E[T006]
assert_type(d.pop("a"), int)
good1: dict[str, int] = d.copy()

# Errors
bad1: str = d.get("a")  # E[T001]
bad2: str = d.pop("a")  # E[T001]
bad3: int = d.clear()  # E[T001]
assert_type(d.get("a"), str)  # E[T006]
bad4: int = d.copy()  # E[T001]
