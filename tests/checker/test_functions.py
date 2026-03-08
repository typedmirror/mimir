# Function type checking test — parameter types, return types, calls
# Expected: T003 for bad return, T002 for wrong arg type, T004 for wrong arg count

def greet(name: str) -> str:
    return "Hello, " + name   # ok: str + str = str

# Bad return: returns str but declared int → T003
def bad_return() -> int:
    return "oops"

# Call with wrong type → T002
greet(42)

# Too few args → T004
greet()

# Correct usage
greet("world")
