from typing import Protocol

class Serializable(Protocol):
    def serialize(self) -> str:
        return ""
    def deserialize(self, data: str) -> None:
        pass

class JsonObj:
    def serialize(self) -> str:
        return "{}"
    def deserialize(self, data: str) -> None:
        pass

class Partial:
    def serialize(self) -> str:
        return ""
    # Missing deserialize

class NoMatch:
    pass

def save(obj: Serializable) -> str:
    return obj.serialize()

# Full match
save(JsonObj())

# Partial match — missing deserialize
save(Partial())  # E[T002]

# No match at all
save(NoMatch())  # E[T002]
