from typing import assert_type, Union

# Function returning Union — both branches valid
def classify(x: int) -> Union[str, int]:
    if x > 0:
        return "positive"
    else:
        return -1

r = classify(5)
assert_type(r, Union[str, int])

# Wrong return type for Union
def bad_classify(x: int) -> Union[str, int]:
    return [1, 2]  # E[T003]
