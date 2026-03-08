# Container type checking test — list, dict, set, tuple
# Expected: T001 for mismatched container assignments

# Valid container annotations
xs: list[int] = [1, 2, 3]
d: dict[str, int] = {"a": 1, "b": 2}

# List type mismatch → T001
bad_list: list[str] = [1, 2, 3]

# Inferred containers
nums = [1, 2, 3]        # list[int]
names = ["a", "b"]      # list[str]
mapping = {"x": 1}      # dict[str, int]
pair = (1, "two")       # tuple[int, str]
