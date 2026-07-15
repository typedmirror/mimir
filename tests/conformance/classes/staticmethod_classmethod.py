from typing import assert_type

class Foo:
    @staticmethod
    def create(x: int) -> str:
        return str(x)

    @classmethod
    def from_string(cls, s: str) -> int:
        return int(s)

    def normal(self, x: int) -> int:
        return x

# Static method — no self
result = Foo.create(42)
assert_type(result, str)

# Class method — cls stripped
result2 = Foo.from_string("42")
assert_type(result2, int)

# Normal method — self stripped
f = Foo()
result3 = f.normal(10)
assert_type(result3, int)

# Wrong arg type to static
bad = Foo.create("wrong")  # E[T002]
