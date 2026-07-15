# Container operations
a: list[int] = [1, 2] + [3, 4]  # list concat
b: str = "hello" + " " + "world"
# Errors
bad: list[str] = [1, 2] + [3, 4]  # E[T001]
bad2: int = [1] + [2]             # E[T001]
