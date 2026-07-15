# Subtype promotion conformance

# Valid promotions — no errors
f1: float = 5         # int -> float (implicit widening)
f2: float = True      # bool -> int -> float
i1: int = True        # bool -> int (bool is subclass of int)

# Invalid promotions
bad1: int = 3.14      # E[T001]: float not assignable to int
bad2: bool = 42       # E[T001]: int not assignable to bool
bad3: str = 5         # E[T001]: int not assignable to str
bad4: int = "hello"   # E[T001]: str not assignable to int
