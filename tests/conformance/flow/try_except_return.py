from typing import assert_type

# Try/except with return in both branches
def parse_int(text: str) -> int:
    try:
        return int(text)
    except:
        return -1
