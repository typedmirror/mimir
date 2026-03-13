from typing import assert_type
from dataclasses import dataclass

@dataclass
class Config:
    host: str
    port: int

def load_config():
    c = Config("localhost", 8080)
    assert_type(c, Config)
    return c

r = load_config()
assert_type(r, Config)
