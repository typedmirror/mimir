from typing import assert_type, Union

# Four-type union exhausted via isinstance chain
def format_val(x: Union[int, str, float, bool]) -> str:
    if isinstance(x, bool):
        assert_type(x, bool)
        return "bool"
    elif isinstance(x, int):
        assert_type(x, int)
        return "int"
    elif isinstance(x, str):
        assert_type(x, str)
        return "str"
    else:
        assert_type(x, float)
        return "float"
