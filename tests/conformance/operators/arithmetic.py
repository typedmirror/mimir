# Arithmetic operator type checking conformance

# Valid operations — no errors
a = 1 + 2
b = 3.14 + 1.0
c = 1 + 3.14       # int + float ok
d = "hello" + " world"  # str + str ok
e = 2 * 3
f = 10 / 2

# Invalid operations
bad1 = "hello" + 42    # E[T005]: unsupported operand types
bad2 = 42 + "hello"    # E[T005]: unsupported operand types
bad3 = "hello" - "world"  # E[T005]: unsupported operand types
bad4 = "hello" / 2     # E[T005]: unsupported operand types
