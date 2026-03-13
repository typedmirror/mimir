from typing import assert_type, Union

# Three-type union narrowed via isinstance chain
def classify(x: Union[int, str, float]) -> str:
    if isinstance(x, int):
        assert_type(x, int)
        return "int"
    elif isinstance(x, str):
        assert_type(x, str)
        return "str"
    else:
        assert_type(x, float)
        return "float"
