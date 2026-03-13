from typing import assert_type, Union

# Three-way isinstance narrowing with subtraction
def classify(x: Union[int, str, float]) -> str:
    if isinstance(x, int):
        assert_type(x, int)
        return "integer"
    elif isinstance(x, str):
        assert_type(x, str)
        return "string"
    else:
        assert_type(x, float)
        return "float"
