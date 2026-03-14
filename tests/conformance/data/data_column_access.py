from typing import TypedDict, assert_type
from mimir.data import read_csv, DataFrame

class Schema(TypedDict):
    name: str
    age: int
    score: float

df = read_csv("data.csv", Schema)

name_col = df["name"]
age_col = df["age"]
score_col = df["score"]

assert_type(name_col.count(), int)
assert_type(age_col.sum(), int)
assert_type(score_col.mean(), float)

sub = df[["name", "age"]]
assert_type(sub, DataFrame)
