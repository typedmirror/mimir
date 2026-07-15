from typing import assert_type, Dict, List

# Correctly annotated nested container
d: Dict[str, List[int]] = {"nums": [1, 2, 3]}
assert_type(d, Dict[str, List[int]])

# Correctly annotated list of lists
ll: List[List[str]] = [["a", "b"], ["c"]]
assert_type(ll, List[List[str]])

# Wrong inner type — list[int] where list[str] expected
bad: Dict[str, List[str]] = {"nums": [1, 2, 3]}  # E[T001]
