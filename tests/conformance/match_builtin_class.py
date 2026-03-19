# Tests for builtin class patterns in match statements
# case int() should narrow to int type, enabling MATCH002 subsumption

def classify_int(x: int) -> str:
    match x:
        case int():
            return "integer"
        case _:
            return "other"

def classify_str(x: str) -> str:
    match x:
        case str():
            return "string"
        case _:
            return "other"

# Builtin class pattern should narrow correctly
def narrow_bool(x: object) -> str:
    match x:
        case bool():
            return "bool"
        case int():
            return "int"
        case _:
            return "other"
