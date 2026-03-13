from typing import assert_type

class Ok:
    value: int
    def __init__(self, value: int):
        self.value = value

class Err:
    msg: str
    def __init__(self, msg: str):
        self.msg = msg

# Returning wrong class type from function
def divide(a: int, b: int) -> Ok:
    if b == 0:
        return Err("division by zero")  # E
    return Ok(a)
