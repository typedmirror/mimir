"""DataFrame column tracking: validate column access and propagation."""

from mimir.data import read_csv, DataFrame

# Schema-based read: columns known at compile time
# df = read_csv("sales.csv", schema={"region": str, "price": float, "qty": int})
# For now, use DataFrame constructor with known columns

# Column assignment builds up the type
df = DataFrame()
df["region"] = "east"
df["price"] = 9.99
df["qty"] = 10

# Valid column access
region = df["region"]     # OK: known column
price = df["price"]       # OK: known column

# Invalid column access
bad = df["shipping_cost"]  # E: column not found
