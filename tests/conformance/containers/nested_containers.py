from typing import Dict, List, assert_type

# Nested container type
d: Dict[str, List[int]] = {"nums": [1, 2, 3]}

# Access returns correct inner type
r = d["nums"]
assert_type(r, List[int])

# Wrong inner type
bad: Dict[str, List[str]] = d  # E
