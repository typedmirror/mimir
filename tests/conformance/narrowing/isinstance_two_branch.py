from typing import assert_type, Union

# isinstance positive and negative branches
def process(x: Union[int, str]) -> str:
    if isinstance(x, int):
        assert_type(x, int)
        return str(x)
    assert_type(x, str)
    return x
