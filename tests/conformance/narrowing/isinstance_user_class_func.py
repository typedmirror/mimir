from typing import assert_type, Union

class A:
    pass

class B:
    pass

# isinstance narrowing with user classes in function scope
def check_type(x: Union[A, B]):
    if isinstance(x, A):
        assert_type(x, A)
    else:
        assert_type(x, B)
