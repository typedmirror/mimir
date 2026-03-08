# Basic type checking test — literals, annotations, assignments
# Expected: T001 errors for mismatched assignments

# Correct assignments
x: int = 5
y: str = "hello"
z: float = 3.14
b: bool = True
n: int = 0

# Inferred from literals
a = 42         # int
c = "world"    # str
d = 1.5        # float

# Type mismatch: str annotation, int value → T001
bad1: str = 5

# Type mismatch: int annotation, str value → T001
bad2: int = "oops"
