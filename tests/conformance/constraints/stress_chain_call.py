# Stress: method chains — should not crash

class Builder:
    def set_name(self, name: str) -> "Builder":
        return self
    def set_age(self, age: int) -> "Builder":
        return self
    def build(self) -> str:
        return "done"

result: int = Builder().set_name("Alice").set_age(30).build()  # E: Incompatible types
