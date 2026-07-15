# Builtin function return types
x: int = len("hello")
y: int = len([1, 2, 3])
z: bool = isinstance(42, int)
a: str = input()
b: str = repr(42)
c: int = hash("x")
d: int = abs(-5)
# Errors
bad1: str = len("hello")  # E[T001]
bad2: int = input()        # E[T001]
bad3: str = isinstance(1, int)  # E[T001]
