# Self type: method return type refers to enclosing class

from typing import Self

class MyClass:
    def copy(self) -> Self:
        return self

    def value(self) -> int:
        return 42

obj = MyClass()
obj2 = obj.copy()

# obj2 is MyClass (Self resolves to MyClass), can call .value()
result: int = obj2.value()

# Self return is MyClass, not int
wrong: int = obj.copy()  # E: Incompatible types
