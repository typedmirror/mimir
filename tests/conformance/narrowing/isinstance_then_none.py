from typing import assert_type, Union

# isinstance narrows first, None narrows second
def process(x: Union[int, str, None]) -> str:
    if isinstance(x, int):
        assert_type(x, int)
        return str(x)
    elif x is None:
        return "none"
    else:
        assert_type(x, str)
        return x
