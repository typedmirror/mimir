from typing import assert_type

# Reassignment type error in function scope
def reassign_error():
    x: int = 10
    x = "hello"  # E
