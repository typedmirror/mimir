from typing import assert_type, Dict

# Iterating dict gives key type
d: Dict[str, int] = {"a": 1, "b": 2}
for key in d:
    assert_type(key, str)
