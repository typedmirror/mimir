# Augmented assignment type checking
x: int = 10
x += 5   # OK: int += int
x -= 1   # OK: int -= int

y: str = "hello"
y += " world"  # OK: str += str

# Type mismatch in augmented assignment
x += "bad"  # E[T005]
y += 42  # E[T005]
