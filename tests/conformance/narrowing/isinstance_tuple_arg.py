from typing import assert_type, Union

# isinstance with tuple type arg — narrows to union, else subtracts
def check(x: Union[int, str, float]):
    if isinstance(x, (int, str)):
        assert_type(x, int | str)
    else:
        assert_type(x, float)
