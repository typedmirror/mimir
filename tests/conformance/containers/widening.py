# Container element widening

# bool widens to int in list context
x: list[int] = [True, False]

# bool widens to int in annotated assignment
y: list[int] = [True, 1, False, 2]

# Mixed widening — int widens to float
z: list[float] = [1, 2, 3]

# Widening should NOT happen when types don't match
a: list[str] = [1, 2, 3]  # E[T001]

# Dict key/value widening
b: dict[str, float] = {"x": 1, "y": 2}
