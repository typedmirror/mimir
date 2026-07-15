# None type and Optional conformance

# None as a value — no errors
x: None = None

# Optional (union with None)
opt1: int | None = None     # ok
opt2: int | None = 42       # ok
opt3: str | None = "hello"  # ok
opt4: str | None = None     # ok

# Mismatch with Optional
bad1: int | None = "oops"   # E[T001]: str not assignable to int | None
bad2: str | None = 42       # E[T001]: int not assignable to str | None
