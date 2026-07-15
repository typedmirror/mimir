from typing import Protocol

class HasLen(Protocol):
    def __len__(self) -> int: ...

class WithLen:
    def __len__(self) -> int:
        return 0

class NoLen:
    pass

def get_length(obj: HasLen) -> int:
    return obj.__len__()

# Matches protocol
get_length(WithLen())

# Missing __len__ method
get_length(NoLen())  # E[T002]
