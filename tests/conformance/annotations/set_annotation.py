# set[T] annotations
x: set[int] = {1, 2, 3}
y: set[str] = {"a", "b"}
# Contextual typing for sets
z: set[int] = {True, False}  # bool widens to int
bad1: set[str] = {1, 2}  # E
bad2: set[int] = {"a"}   # E
