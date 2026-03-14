from typing import TypedDict, assert_type
from mimir.data import read_csv, DataFrame

class Data(TypedDict):
    x: float
    y: float

df = read_csv("data.csv", Data)

sorted_df = df.sort_values("x")
assert_type(sorted_df, DataFrame)

top = df.head(10)
assert_type(top, DataFrame)

clean = df.dropna()
assert_type(clean, DataFrame)

cols = df.columns
assert_type(cols, list)

shape = df.shape
assert_type(shape, tuple)
