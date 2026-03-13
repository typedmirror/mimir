from typing import assert_type, Union

class Success:
    value: int
    def __init__(self, value: int):
        self.value = value

class Failure:
    msg: str
    def __init__(self, msg: str):
        self.msg = msg

# Conditional class construction in function — returns union
def try_parse(s: str) -> Union[Success, Failure]:
    if len(s) > 0:
        return Success(42)
    return Failure("empty")
