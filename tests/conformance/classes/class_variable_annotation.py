from typing import assert_type

class Config:
    debug: bool = False
    max_retries: int = 3
    name: str = "default"

    def __init__(self, name: str) -> None:
        self.name = name

c = Config("test")

# Instance access uses annotated types
assert_type(c.debug, bool)
assert_type(c.max_retries, int)
assert_type(c.name, str)

# Class-level access
assert_type(Config.debug, bool)
assert_type(Config.max_retries, int)
