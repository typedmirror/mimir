# §3.4: Multi-param specialization — tests param index mapping

def pair(a, b):
    return a

# Multiple callers with different type patterns
r1 = pair(1, "x")
r2 = pair("hello", 42)

# Correctly typed per call site — return type follows first param
x: int = pair(3, "y")
y: str = pair("a", 99)

# Incorrectly typed
z: str = pair(3, "y")  # E[T001]: Incompatible types
w: int = pair("a", 99)  # E[T001]: Incompatible types
