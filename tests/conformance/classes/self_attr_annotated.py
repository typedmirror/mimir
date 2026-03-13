from typing import assert_type

class Container:
    def __init__(self) -> None:
        self.items: list[int] = []
        self.name = "default"
        self.data: dict[str, int] = {}
        self.count = 0

c = Container()

# Annotated attrs get their annotation type
assert_type(c.items, list[int])
assert_type(c.data, dict[str, int])

# Inferred attrs get literal type
assert_type(c.name, str)
assert_type(c.count, int)

# Nonexistent attr
c.missing  # E
