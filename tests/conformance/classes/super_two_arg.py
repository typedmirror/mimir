class Base:
    def method(self) -> int:
        return 1

class Child(Base):
    def method(self) -> int:
        return super().method() + 1

class Child2(Base):
    def method(self) -> int:
        return super(Child2, self).method() + 1
