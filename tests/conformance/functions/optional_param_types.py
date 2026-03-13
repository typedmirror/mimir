from typing import assert_type, Optional

def greet(name: str, greeting: Optional[str] = None) -> str:
    if greeting is not None:
        return f"{greeting}, {name}"
    return f"Hello, {name}"

# Call with required arg only
r1 = greet("Alice")
assert_type(r1, str)

# Call with both args
r2 = greet("Bob", "Hi")
assert_type(r2, str)

# Wrong type for required param
greet(42)  # E
