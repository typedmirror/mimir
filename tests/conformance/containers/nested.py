# Nested container types
x: list[list[int]] = [[1, 2], [3, 4]]
y: dict[str, list[int]] = {"a": [1, 2], "b": [3]}
z: list[dict[str, int]] = [{"x": 1}, {"y": 2}]
# Contextual typing propagates through nesting
w: list[list[int]] = [[True, False], [1, 2]]  # bool widens
# Errors
bad: list[list[str]] = [[1, 2]]  # E
bad2: dict[str, list[str]] = {"a": [1, 2]}  # E
