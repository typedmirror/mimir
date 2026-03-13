from typing import assert_type

class Result:
    ok: bool
    def __init__(self, ok: bool):
        self.ok = ok

# Multiple return paths all constructing same class
def process(x: int) -> Result:
    if x > 0:
        return Result(True)
    elif x == 0:
        return Result(False)
    else:
        return Result(False)
