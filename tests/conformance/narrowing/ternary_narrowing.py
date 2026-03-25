"""Ternary narrowing: isinstance/None guards narrow types in if-expr branches."""
from typing import Union, Optional, assert_type

# isinstance narrowing in ternary — both branches same type
def ternary_isinstance_same(x: Union[int, str]) -> None:
    a = x if isinstance(x, int) else 0
    assert_type(a, int)

# None narrowing in ternary — method call in narrowed branch
def ternary_none_method(x: Optional[str]) -> None:
    a = x.upper() if x is not None else "default"
    assert_type(a, str)

# Truthiness narrowing in ternary
def ternary_truthy(x: Optional[int]) -> None:
    a = x if x else 0
    assert_type(a, int)

# isinstance narrowing — narrowed body type
def ternary_isinstance_int(x: object) -> None:
    a = x + 1 if isinstance(x, int) else 0
    assert_type(a, int)
