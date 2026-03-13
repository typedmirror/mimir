def returns_str() -> str:
    return 42  # E

def returns_int() -> int:
    return "hello"  # E

def returns_bool() -> bool:
    return 3.14  # E

def returns_list() -> list[int]:
    return "not a list"  # E
