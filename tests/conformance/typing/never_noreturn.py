from typing import Never, NoReturn

# Never as return type — function that never returns
def fail_hard() -> Never:
    raise RuntimeError("fatal")

def also_fails() -> NoReturn:
    raise SystemExit(1)

# Functions with Never return can still be called
fail_hard()
also_fails()
