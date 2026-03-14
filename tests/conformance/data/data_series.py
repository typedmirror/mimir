from typing import TypedDict, assert_type
from mimir.data import read_csv

class Stats(TypedDict):
    score: float
    name: str

df = read_csv("stats.csv", Stats)
s = df["score"]

avg = s.mean()
assert_type(avg, float)

total = s.sum()
assert_type(total, float)

n = s.count()
assert_type(n, int)

vals = s.values
assert_type(vals, list)

top = s.head(5)
assert_type(top.mean(), float)
