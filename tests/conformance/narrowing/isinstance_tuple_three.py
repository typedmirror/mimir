from typing import assert_type, Union

# isinstance tuple arg + elif chain with subtraction
def classify(x: Union[int, str, float, bool]):
    if isinstance(x, (int, bool)):
        assert_type(x, int | bool)
    elif isinstance(x, str):
        assert_type(x, str)
    else:
        assert_type(x, float)
