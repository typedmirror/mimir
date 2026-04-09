"""TypeVarTuple (PEP 646) — variadic generics."""
from typing import TypeVarTuple, Tuple, assert_type

Ts = TypeVarTuple('Ts')

# Variadic tuple annotation — fixed head, variadic tail
def head(t: Tuple[int, *Ts]) -> int:
    return t[0]

# Fixed elements match, variadic captures rest
x = head((1, "hello", 3.14))
assert_type(x, int)
