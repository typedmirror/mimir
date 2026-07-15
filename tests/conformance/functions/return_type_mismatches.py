def returns_str() -> str:
    return 42  # E[T003]

def returns_int() -> int:
    return "hello"  # E[T003]

def returns_bool() -> bool:
    return 3.14  # E[T003]

def returns_list() -> list[int]:
    return "not a list"  # E[T003]
