# Method call caller→param: obj.method(42) → param inferred, return propagated

class Calc:
    def add(self, x, y):
        return x + y

c = Calc()
result: str = c.add(1, 2)  # E: Incompatible types
