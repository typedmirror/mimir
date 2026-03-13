from typing import assert_type

# Variable type consistent across try/except branches
try:
    x: int = 42
except ValueError:
    x = 0

assert_type(x, int)

# Function with try/except return
def safe_parse(s: str) -> int:
    try:
        return int(s)
    except ValueError:
        return -1

r = safe_parse("42")
assert_type(r, int)
