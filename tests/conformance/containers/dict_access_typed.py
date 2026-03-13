from typing import assert_type, Dict

# Dict subscript returns value type
d: Dict[str, int] = {"x": 1, "y": 2}
val = d["x"]
assert_type(val, int)

# Wrong type from dict access
bad: str = d["x"]  # E
