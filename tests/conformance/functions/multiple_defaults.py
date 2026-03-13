from typing import assert_type

# Function with multiple default params
def connect(host: str, port: int, timeout: int) -> str:
    return host

# All args provided
r1 = connect("localhost", 8080, 30)
assert_type(r1, str)

# Wrong type
connect("localhost", "not_int", 30)  # E
