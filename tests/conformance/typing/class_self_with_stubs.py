"""Class self attribute resolution with typing imports.
Regression test: Union[Class, str] return type from typeshed stubs
caused scope_id collision — self resolved to TypeVar instead of Instance.
"""
from typing import Union, List

class Config:
    def __init__(self, path: str, mode: str) -> None:
        self.path = path
        self.mode = mode

def parse() -> Union[Config, str]:
    return Config(".", "run")

class Stats:
    def __init__(self) -> None:
        self.count: int = 0
        self.total: float = 0.0

    def average(self) -> float:
        if self.count == 0:
            return 0.0
        return self.total / self.count

def run() -> None:
    s = Stats()
    s.count = 10
    s.total = 50.0
    avg = s.average()
