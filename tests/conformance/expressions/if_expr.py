# Ternary expression type checking
x: int = 1 if True else 2
y: str = "a" if True else "b"

# Union result
z = 1 if True else "a"    # z is int | str
a: int = z        # E  — int | str not assignable to int
b: str = z        # E  — int | str not assignable to str

# Nested ternary
w: int = 1 if True else (2 if False else 3)
bad: str = 1 if True else 2    # E
