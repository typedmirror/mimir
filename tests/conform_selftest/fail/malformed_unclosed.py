# conform self-test fixture (T3a, fixture iv-a): malformed marker, unclosed bracket.
# The marker on the last line is missing its closing bracket. An author who
# opened a bracket meant a code marker; degrading to a bare marker would
# silently assert less. This file MUST FAIL with a loud malformed-marker error.
x: int = "hello"  # E[T001
