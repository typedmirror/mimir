from typing import assert_type

# Container annotation mismatch inside function scope
def wrong_list_elem():
    xs: list[int] = [1, 2, "three"]  # E
