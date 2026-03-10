from typing import assert_type

s: str = "hello"

# Correct: assert_type validates return types
assert_type(s.upper(), str)
assert_type(s.find("x"), int)
assert_type(s.startswith("h"), bool)
assert_type(s.encode(), bytes)
assert_type(s.replace("h", "j"), str)

# Correct: assignment matches return type
good1: list[str] = s.split()

# Wrong assert_type — T006
assert_type(s.upper(), int)  # E
assert_type(s.find("x"), str)  # E
assert_type(s.startswith("h"), int)  # E
assert_type(s.encode(), str)  # E

# Wrong assignments
bad1: int = s.upper()  # E
bad2: str = s.find("x")  # E
bad3: int = s.encode()  # E
bad4: bool = s.replace("h", "j")  # E
