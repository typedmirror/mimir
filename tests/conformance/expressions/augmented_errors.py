# Augmented assignment type errors (T005)
x: int = 10
x += 5
x += "bad"      # E[T005]  — T005 unsupported operand: int += str

s: str = "hello"
s += " world"
s += 42         # E[T005]  — T005 unsupported operand: str += int
