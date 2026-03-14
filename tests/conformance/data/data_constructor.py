from typing import assert_type
from mimir.data import DataFrame

df = DataFrame({"name": ["Alice", "Bob"], "age": [30, 25]})

name_col = df["name"]
age_col = df["age"]

assert_type(name_col.count(), int)
assert_type(age_col.sum(), int)
