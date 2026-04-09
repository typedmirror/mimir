"""DataFrame column tracking: computed columns and derived DataFrames."""

from mimir.data import DataFrame

# Build DataFrame with known columns
df = DataFrame()
df["price"] = 9.99
df["qty"] = 10

# Computed column — should be tracked
df["revenue"] = df["price"] * df["qty"]

# Valid access of computed column
rev = df["revenue"]  # OK: just assigned

# Multi-column select
subset = df[["price", "qty"]]  # OK: both exist

# Invalid computed column reference
bad = df["total_cost"]  # E: column not found
