from typing import assert_type, Dict, List

# Dict containing lists — inner type preserved
d: Dict[str, List[int]] = {"a": [1, 2], "b": [3]}
val = d["a"]
assert_type(val, List[int])

# Wrong inner type mismatch
bad: Dict[str, List[str]] = {"a": [1, 2]}  # E[T001]
