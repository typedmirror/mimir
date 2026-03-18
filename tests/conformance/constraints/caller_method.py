# Method call caller→param: obj.method(42) provides type evidence
# NOTE: method return type backfill is a pre-existing gap — methods
# with unannotated params + no return annotation don't propagate
# return types even when body inference resolves them.

class Greeter:
    def greet(self, name: str) -> str:
        return "Hello " + name

g = Greeter()
result: int = g.greet("World")  # E: Incompatible types
