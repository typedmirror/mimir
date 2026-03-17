from typing import TypedDict, assert_type
from mimir.data import read_csv, DataFrame

class Order(TypedDict):
    price: float
    qty: int

df = read_csv("orders.csv", Order)

# Column assignment adds new column
df["total"] = df["price"]  # Series assignment

# New column should be accessible
x = df["total"]

# Original columns still accessible
y = df["price"]
z = df["qty"]

# Accessing nonexistent column still errors
w = df["nonexist"]  # E: DATA001
