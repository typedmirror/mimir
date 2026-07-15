# Container method return types
xs: list[int] = [1, 2, 3]
a: int = len(xs)
b: str = len(xs)       # E[T001]  — len returns int

s: str = "hello"
c: int = s.upper()     # E[T001]  — upper returns str
