from typing import Tuple, assert_type

# Heterogeneous tuple
t: Tuple[int, str, float] = (1, "hello", 3.14)

# Tuple assignment to wrong type
bad: Tuple[str, str, str] = t  # E
