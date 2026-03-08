# Return type checking conformance

def good_return() -> int:
    return 42

def good_str() -> str:
    return "hello"

def no_annotation():
    return 42  # ok, no declared return type

def bad_return() -> int:
    return "oops"     # E: str not assignable to int

def bad_return2() -> str:
    return 42         # E: int not assignable to str

def bad_return3() -> bool:
    return "yes"      # E: str not assignable to bool
