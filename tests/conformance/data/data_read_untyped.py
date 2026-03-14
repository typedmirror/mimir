from typing import assert_type
from mimir.data import read_csv, DataFrame

df = read_csv("data.csv")
assert_type(df, DataFrame)

col = df["anything"]
sorted_df = df.sort_values("col")
assert_type(sorted_df, DataFrame)
