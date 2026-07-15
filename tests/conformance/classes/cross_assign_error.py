from typing import assert_type

class Foo:
    x: int
    def __init__(self, x: int):
        self.x = x

class Bar:
    y: str
    def __init__(self, y: str):
        self.y = y

# Cross-class assignment errors in function
def errors():
    f: Foo = Bar("wrong")  # E[T001]
    b: Bar = Foo(42)       # E[T001]
