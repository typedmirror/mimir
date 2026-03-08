# Augmented assignment operator conformance

# Valid augmented assignments — no errors
x: int = 10
x += 5
x -= 3
x *= 2

y: float = 1.0
y += 0.5

s: str = "hello"
s += " world"

# Invalid augmented assignments (augmented op checking not yet implemented)
z: int = 10
z += "bad"    # E?

w: str = "hello"
w -= "world"  # E?
