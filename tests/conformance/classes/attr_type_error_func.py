from typing import assert_type

class Config:
    port: int
    def __init__(self, port: int):
        self.port = port

# Wrong type assigned from class attr in function
def bad_usage():
    c = Config(8080)
    s: str = c.port  # E
