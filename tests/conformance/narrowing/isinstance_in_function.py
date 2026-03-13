from typing import assert_type, Union

# isinstance guard inside function body
def handle(val: Union[int, str]) -> int:
    if isinstance(val, int):
        assert_type(val, int)
        return val
    else:
        assert_type(val, str)
        return len(val)

# Wrong return in else
def bad_handle(val: Union[int, str]) -> int:
    if isinstance(val, int):
        return val
    else:
        return val  # E
