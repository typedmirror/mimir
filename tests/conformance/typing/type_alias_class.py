from typing import assert_type

class Error:
    msg: str
    def __init__(self, msg: str):
        self.msg = msg

# Type alias to class
MyError = Error

def make_error() -> MyError:
    return MyError("oops")

e = make_error()
assert_type(e, Error)
