# Parameter type checking conformance

def greet(name: str) -> str:
    return name

def add(a: int, b: int) -> int:
    return a + b

# Correct calls — no errors
greet("Alice")
add(1, 2)

# Wrong argument types
greet(42)        # E[T002]: int not assignable to str
add("x", "y")   # E[T002]: str not assignable to int
add(1, "y")      # E[T002]: str not assignable to int
