from typing import assert_type

# Function calling another function — type flows through
def helper() -> int:
    return 42

def main() -> str:
    x = helper()
    assert_type(x, int)
    return str(x)

r = main()
assert_type(r, str)

# Chaining function results
r2 = str(helper())
assert_type(r2, str)
