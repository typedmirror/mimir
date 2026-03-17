from typing import TypedDict, assert_type
from mimir.data import read_csv, DataFrame

class Products(TypedDict):
    name: str
    price: float
    stock: int

df = read_csv("products.csv", Products)

# Boolean filter preserves columns
filtered = df[df["price"] > 100]
assert_type(filtered, DataFrame)
# Columns still accessible after filter
x = filtered["name"]
y = filtered["price"]
