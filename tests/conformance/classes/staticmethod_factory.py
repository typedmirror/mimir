from typing import assert_type

class Config:
    def __init__(self, value: int) -> None:
        self.value = value

    @staticmethod
    def default() -> int:
        return 42

    @classmethod
    def from_string(cls, s: str) -> int:
        return int(s)

# Static method returns int
r1 = Config.default()
assert_type(r1, int)

# Classmethod returns int
r2 = Config.from_string("10")
assert_type(r2, int)

# Too many args to static method (takes 0)
Config.default(1)  # E[T004]

# Wrong type to classmethod (expects str)
Config.from_string(42)  # E[T002]
