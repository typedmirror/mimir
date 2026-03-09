# Walrus operator (:=)
if (x := 10) > 5:
    y: int = x

# Type propagation
z: int = (w := 42)
bad: str = (v := 42)  # E
