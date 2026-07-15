# Basic type assignment conformance

# Correct assignments — no errors
x: int = 5
y: str = "hello"
z: float = 3.14
b: bool = True
n: bytes = b"data"

# Inferred literals — no errors
a = 42
c = "world"
d = 3.14
e = True

# Type mismatches
bad1: str = 5        # E[T001]: int not assignable to str
bad2: int = "oops"   # E[T001]: str not assignable to int
bad3: bool = "yes"   # E[T001]: str not assignable to bool
bad4: bytes = 42     # E[T001]: int not assignable to bytes

# None assignment
none_var: None = None  # ok
