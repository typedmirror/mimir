# tuple type inference and checking conformance

# Annotated tuples — no errors
pair: tuple[int, str] = (1, "hello")

# Mismatches
bad1: tuple[int, str] = ("hello", 1)  # E[T001]
