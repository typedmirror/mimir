# conform self-test fixture (T3a, fixture iv-c): malformed marker, garbage code.
# The bracket content is not a valid diagnostic code (codes are uppercase
# letters followed by digits). This file MUST FAIL with a loud runner error.
x: int = "hello"  # E[t0-01!]
