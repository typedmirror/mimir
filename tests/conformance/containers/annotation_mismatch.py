from typing import assert_type

# Wrong element type in annotated list
bad_list: list[int] = [1, "two", 3]  # E[T001]

# Wrong value type in annotated dict
bad_dict: dict[str, int] = {"a": "one"}  # E[T001]

# Correct annotated containers
good_list: list[str] = ["a", "b"]
assert_type(good_list, list[str])

good_dict: dict[str, int] = {"a": 1}
assert_type(good_dict, dict[str, int])

# Wrong key type
bad_keys: dict[int, str] = {"a": "b"}  # E[T001]
