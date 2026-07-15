# Method parameter and return type checking
class Counter:
    def __init__(self, n: int) -> None:
        self.count = n

    def get(self) -> int:
        return self.count

    def add(self, x: int) -> None:
        self.count = self.count + x

c = Counter(0)
a: int = c.get()
b: str = c.get()       # E[T001]
c.add(1)
c.add("bad")           # E[T002]

d = Counter("bad")     # E[T002]
e: str = Counter(0).get()  # E[T001]
