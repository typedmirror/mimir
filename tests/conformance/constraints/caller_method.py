# Method call: annotated method return type propagates through revalidation

class Calc:
    def add(self, x: int, y: int) -> int:
        return x + y

c = Calc()
result: str = c.add(1, 2)  # E: Incompatible types
