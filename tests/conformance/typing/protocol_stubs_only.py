from typing import Protocol

# Protocol with all stub methods (ellipsis body)
class Readable(Protocol):
    def read(self) -> str: ...
    def close(self) -> None: ...

# Protocol with pass body stubs
class Writable(Protocol):
    def write(self, data: str) -> int:
        pass
    def flush(self) -> None:
        pass

# Protocol with mixed stubs
class Stream(Protocol):
    def read(self) -> bytes: ...
    def write(self, data: bytes) -> int:
        pass
    def close(self) -> None: ...
