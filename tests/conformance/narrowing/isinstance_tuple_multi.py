from typing import Union

# isinstance with tuple narrows to union of types
def process(x: Union[int, str, float, list]) -> str:
    if isinstance(x, (int, float)):
        return str(x)
    elif isinstance(x, str):
        return x
    else:
        return "list"

# Wrong return in branch
def bad_process(x: Union[int, str]) -> int:
    if isinstance(x, int):
        return x
    else:
        return x  # E
