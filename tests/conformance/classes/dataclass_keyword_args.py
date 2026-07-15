from typing import assert_type
from dataclasses import dataclass

@dataclass
class Config:
    host: str
    port: int
    debug: bool

# Keyword construction
c = Config(host="localhost", port=8080, debug=True)
assert_type(c.host, str)
assert_type(c.port, int)
assert_type(c.debug, bool)

# Wrong keyword arg type
Config(host="localhost", port="not_int", debug=True)  # E[T002]
