from typing import assert_type

class Status:
    code: int
    msg: str
    def __init__(self, code: int, msg: str):
        self.code = code
        self.msg = msg

# Conditional class construction with same type
def get_status(ok: bool) -> Status:
    if ok:
        return Status(200, "ok")
    return Status(500, "error")

r = get_status(True)
assert_type(r, Status)
