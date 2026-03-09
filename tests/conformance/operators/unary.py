# Unary operators
x: int = -5
y: float = -3.14
z: bool = not True
w: int = ~42
# Result type checking
bad: str = -5  # E
bad2: str = ~42  # E
