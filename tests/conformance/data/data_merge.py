from typing import TypedDict, assert_type
from mimir.data import read_csv, DataFrame

class Users(TypedDict):
    user_id: int
    name: str

class Orders(TypedDict):
    user_id: int
    amount: float

users = read_csv("users.csv", Users)
orders = read_csv("orders.csv", Orders)

# Merge combines columns from both DataFrames
merged = users.merge(orders, on="user_id")
assert_type(merged, DataFrame)
# Columns from both sides accessible
x = merged["name"]
y = merged["amount"]
z = merged["user_id"]

# Rename updates column names
renamed = users.rename(columns={"name": "username"})
assert_type(renamed, DataFrame)
a = renamed["username"]
b = renamed["user_id"]

# Old name should error after rename
c = renamed["name"]  # E: DATA001
