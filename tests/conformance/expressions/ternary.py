# Ternary (if_expr) type inference
x: int = 1 if True else 2
y: str = "a" if True else "b"
# Contextual typing through ternary
z: list[int] = [] if True else [1, 2, 3]
# Mixed types
flag: bool = True
w = 1 if flag else "two"  # w should be int | str
bad: str = 1 if True else 2  # E[T001]
