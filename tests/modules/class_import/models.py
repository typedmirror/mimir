class User:
    def __init__(self, name: str) -> None:
        self.name = name

    def greet(self) -> str:
        return "Hello, " + self.name
