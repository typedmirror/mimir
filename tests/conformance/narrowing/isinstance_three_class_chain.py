from typing import assert_type, Union

class Red:
    pass

class Green:
    pass

class Blue:
    pass

# Three-way isinstance chain with user classes in function
def classify(c: Union[Red, Green, Blue]) -> str:
    if isinstance(c, Red):
        assert_type(c, Red)
        return "red"
    elif isinstance(c, Green):
        assert_type(c, Green)
        return "green"
    else:
        assert_type(c, Blue)
        return "blue"
