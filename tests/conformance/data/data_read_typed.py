from typing import TypedDict, assert_type
from mimir.data import read_csv, read_json, DataFrame

class Sales(TypedDict):
    revenue: float
    region: str

df = read_csv("sales.csv", Sales)
assert_type(df, DataFrame)

col = df["revenue"]
assert_type(col.sum(), float)

region = df["region"]
assert_type(region.count(), int)

df2 = read_json("sales.json", Sales)
assert_type(df2, DataFrame)
