class Base:
    def greet(self) -> str:
        return "hello"

class Child(Base):
    def greet(self) -> str:
        result = super().greet()
        x: int = result  # E
        return result
