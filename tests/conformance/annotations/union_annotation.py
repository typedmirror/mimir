from typing import Union, assert_type

# Union annotation
def accept_union(x: Union[int, str]) -> None:
    pass

accept_union(42)
accept_union("hello")

# PEP 604 syntax
def accept_pipe(x: int | str) -> None:
    pass

accept_pipe(42)
accept_pipe("hello")

# Wrong type
accept_union(3.14)  # E[T002]
accept_pipe(3.14)  # E[T002]
