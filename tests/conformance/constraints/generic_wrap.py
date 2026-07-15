# §3.4: Container return specialization — wrap produces list[T]

def wrap(x):
    return [x]

# Multiple callers
a = wrap("hello")
b = wrap(42)

# Correctly typed
c: list = wrap("test")
d: list = wrap(99)

# Incorrectly typed — list[str] is not assignable to int
e: int = wrap("test")  # E[T001]: Incompatible types
f: str = wrap(99)  # E[T001]: Incompatible types
