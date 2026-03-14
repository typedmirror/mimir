# Function with no return → inferred return type is None

from typing import assert_type

def do_nothing():
    x = 42

result = do_nothing()
assert_type(result, None)
