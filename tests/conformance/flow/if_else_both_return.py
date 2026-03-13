from typing import assert_type

# Both branches return correct type
def classify(x: int) -> str:
    if x >= 0:
        return "non-negative"
    else:
        return "negative"

r = classify(-1)
assert_type(r, str)

# Wrong return in else branch
def bad_classify(x: int) -> str:
    if x >= 0:
        return "non-negative"
    else:
        return -1  # E
