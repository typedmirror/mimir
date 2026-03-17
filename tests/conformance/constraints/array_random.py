from typing import assert_type
from mimir.array import random

# Random generation
a = random.normal(0.0, 1.0, (3, 4))
b = random.uniform(0.0, 1.0, (5,))
c = random.randint(0, 10, (3,))
random.seed(42)
