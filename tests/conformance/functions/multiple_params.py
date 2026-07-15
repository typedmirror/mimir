from typing import assert_type

# Function with many typed params
def create_user(name: str, age: int, active: bool) -> str:
    return name

r = create_user("Alice", 30, True)
assert_type(r, str)

# Wrong type for middle param
create_user("Alice", "thirty", True)  # E[T002]
