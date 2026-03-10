from typing import assert_type

d: dict[str, int] = {"a": 1}

# Correct
assert_type(d.get("a"), int)
assert_type(d.pop("a"), int)
good1: dict[str, int] = d.copy()

# Errors
bad1: str = d.get("a")  # E
bad2: str = d.pop("a")  # E
bad3: int = d.clear()  # E
assert_type(d.get("a"), str)  # E
bad4: int = d.copy()  # E
