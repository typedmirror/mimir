from typing import assert_type

# Reassignment must respect declared annotation
x: int = 42
x = 10  # OK — int to int

y: str = "hello"
y = "world"  # OK — str to str

# Bad reassignments
x = "hello"  # E[T001]
y = 42  # E[T001]

# Bool to int is OK (bool <: int)
z: int = 1
z = True  # OK

# Int to float is OK (int <: float)
w: float = 1.0
w = 42  # OK

# Float to int is NOT OK
v: int = 1
v = 3.14  # E[T001]
