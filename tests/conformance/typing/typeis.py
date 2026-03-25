"""TypeIs (PEP 742): narrows type in both true AND false branches."""
from typing import Union, assert_type
from typing_extensions import TypeIs

def is_str(val: Union[str, int]) -> TypeIs[str]:
    return isinstance(val, str)

def use_typeis(x: Union[str, int]) -> None:
    if is_str(x):
        # True branch: x narrowed to str
        assert_type(x, str)
    else:
        # False branch: x narrowed to int (str subtracted from str | int)
        assert_type(x, int)
