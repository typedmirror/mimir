from typing import Dict, assert_type

# Dict value type via subscript
d: Dict[str, int] = {"a": 1, "b": 2}
val = d["a"]
assert_type(val, int)

# Dict with complex value type
d2: Dict[str, float] = {"pi": 3.14}
v2 = d2["pi"]
assert_type(v2, float)

# Wrong value type assignment
bad: str = d["a"]  # E[T001]
