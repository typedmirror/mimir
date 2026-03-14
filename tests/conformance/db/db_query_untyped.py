"""mimir.db untyped query returns list."""
from typing import assert_type
from mimir.db import connect, query

db = connect("sqlite:///app.db")

# Untyped query — no result= keyword
rows = query(db, "SELECT * FROM users")

# Parameterized query — safe
filtered = query(db, "SELECT * FROM users WHERE id = ?", params=[42])
