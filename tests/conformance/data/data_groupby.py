from typing import TypedDict, assert_type
from mimir.data import read_csv, DataFrame

class Sales(TypedDict):
    region: str
    revenue: float
    quantity: int

df = read_csv("sales.csv", Sales)

# GroupBy with sum → preserves group key, numeric columns
grouped = df.groupby("region")
result = grouped.sum()
assert_type(result, DataFrame)
# Group key preserved, numeric columns preserved
x = result["region"]
y = result["revenue"]

# GroupBy with mean → numeric columns become float
mean_result = grouped.mean()
z = mean_result["revenue"]

# GroupBy with count → all columns become int
count_result = grouped.count()
c = count_result["revenue"]

# Chained groupby: df.groupby("region").sum() (no intermediate variable)
chained = df.groupby("region").sum()
assert_type(chained, DataFrame)
cr = chained["region"]
cv = chained["revenue"]
