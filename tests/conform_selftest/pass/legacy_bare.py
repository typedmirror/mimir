# conform self-test fixture (T3a, fixture iii): legacy markers, pre-T3a semantics.
# Bare marker, text marker, and optional marker must behave exactly as before:
# any error on the marked line matches, regardless of its diagnostic code.
x: int = "hello"  # E
y: str = 123  # E: int is not assignable to str
z = undefined_name_xyz  # E?
