# Never-returning functions suppress F002 (missing return)

from typing import Never

def fail(msg: str) -> Never:
    raise RuntimeError(msg)

# This should NOT get F002 — fail() never returns
def process() -> int:
    fail("done")

# This SHOULD get F002 — no terminating path
def bad() -> int:  # E: missing return statement
    x = 1
