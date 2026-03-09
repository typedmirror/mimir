# Bitwise operators (int only)
a: int = 5 & 3
b: int = 5 | 3
c: int = 5 ^ 3
d: int = 1 << 4
e: int = 16 >> 2
# Result type checking
bad: str = 5 & 3  # E
