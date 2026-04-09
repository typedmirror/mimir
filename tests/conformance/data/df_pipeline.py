"""DataFrame column tracking: realistic DS pipeline with column validation."""

from mimir.data import DataFrame

# Build sales DataFrame
sales = DataFrame()
sales["region"] = "east"
sales["product"] = "widget"
sales["price"] = 29.99
sales["quantity"] = 100

# Computed column
sales["revenue"] = sales["price"] * sales["quantity"]

# Valid: all columns exist
avg_price = sales["price"].mean()
total_rev = sales["revenue"].sum()

# Multi-column select
product_data = sales[["product", "price", "quantity"]]

# Column error: typo
bad = sales["quantiy"]  # E: column not found
