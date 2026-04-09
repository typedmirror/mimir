# Final: immutable variable annotation

from typing import Final

MAX_SIZE: Final[int] = 100
NAME: Final = "mimir"

# Reassignment to Final is an error
MAX_SIZE = 200  # E: Cannot assign to final variable
NAME = "other"  # E: Cannot assign to final variable

# Non-Final reassignment is OK
counter: int = 0
counter = 1
