from typing import List, Dict, Set, assert_type

# Empty containers with contextual typing
x: List[int] = []
assert_type(x, List[int])

y: Dict[str, int] = {}
assert_type(y, Dict[str, int])

z: Set[str] = set()
assert_type(z, Set[str])

# Wrong element type in context
bad: List[str] = [1, 2, 3]  # E
