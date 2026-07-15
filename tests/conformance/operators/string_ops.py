# String operation conformance

# Valid string operations — no errors
s1 = "hello" + " world"   # concatenation
s2 = "abc" * 3             # repetition
s3 = 3 * "abc"             # repetition (reversed)

# Invalid string operations
bad1 = "hello" - "world"   # E[T005]: unsupported operand types
bad2 = "hello" / 2         # E[T005]: unsupported operand types
bad3 = "a" + 1             # E[T005]: unsupported operand types
