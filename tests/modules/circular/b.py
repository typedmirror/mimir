from a import foo

def bar() -> str:
    return "hello"

y: str = foo()    # E  — int not assignable to str
