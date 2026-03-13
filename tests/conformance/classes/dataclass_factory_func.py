from typing import assert_type
from dataclasses import dataclass

@dataclass
class Settings:
    debug: bool
    verbose: bool
    timeout: int

# Dataclass construction in factory functions
def make_default() -> Settings:
    return Settings(False, False, 30)

def make_debug() -> Settings:
    return Settings(True, True, 60)

s = make_default()
assert_type(s, Settings)
