# §3.4: Identity and wrapping patterns with specialization

def identity(x):
    return x

def wrap(x):
    return [x]

# Multiple callers establish generic behavior
a = identity("hello")
b = identity(42)
c = wrap("test")
d = wrap(99)

# Correctly typed — identity specializes per call site
e: str = identity("world")
f: int = identity(100)

# Incorrectly typed — specialized return doesn't match
g: int = identity("world")  # E: Incompatible types
h: str = identity(100)  # E: Incompatible types
