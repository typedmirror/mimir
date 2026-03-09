# Container method return types
xs: list[int] = [1, 2, 3]
a: int = len(xs)
b: str = len(xs)       # E  — len returns int

s: str = "hello"
c: int = s.upper()     # E  — upper returns str
