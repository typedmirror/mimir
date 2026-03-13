from typing import assert_type, Union

# Three-way isinstance narrowing with primitives
def stringify(x: Union[int, float, bool]) -> str:
    if isinstance(x, bool):
        assert_type(x, bool)
        return "bool"
    elif isinstance(x, int):
        assert_type(x, int)
        return "int"
    else:
        assert_type(x, float)
        return "float"
