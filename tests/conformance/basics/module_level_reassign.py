from typing import assert_type

# Module-level typed variable
MAX_SIZE: int = 100
assert_type(MAX_SIZE, int)

# Correct reassignment
MAX_SIZE = 200

# Wrong reassignment at module level
MAX_SIZE = "big"  # E

# Function accessing module-level variable
def get_max() -> int:
    return MAX_SIZE

r = get_max()
assert_type(r, int)
