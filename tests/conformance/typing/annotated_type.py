# Annotated: metadata wrapper — type checker extracts T, ignores metadata

from typing import Annotated

# Annotated[T, metadata] resolves to T
x: Annotated[int, "positive"] = 42
y: Annotated[str, "max_length=100"] = "hello"

# Type checking still works through Annotated
wrong: str = x  # E[T001]: Incompatible types
