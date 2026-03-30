"""Generator[Y, S, R] send type: yield expression returns SendType."""
from typing import Generator

def simple_gen() -> Generator[int, str, None]:
    """yield returns str (the send type), not int (the yield type)."""
    received: str = yield 42  # yield expr has type str
    received2: str = yield 99
    _ = received
    _ = received2
    return

def no_send() -> Generator[int, None, None]:
    """yield returns None when send type is None."""
    result: None = yield 10
    _ = result
    return

def wrong_send_type() -> Generator[int, str, None]:
    received: int = yield 42  # E: Incompatible types in assignment
    _ = received
    return
