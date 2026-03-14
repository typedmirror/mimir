"""mimir.db typed query results via TypedDict."""
from typing import TypedDict, assert_type
from mimir.db import connect, query

class UserRow(TypedDict):
    id: int
    name: str
    email: str

db = connect("sqlite:///app.db")

# Typed query — result= keyword gives list[UserRow]
rows = query(db, "SELECT * FROM users", result=UserRow)
assert_type(rows, list[UserRow])

# Access row fields — type checked via TypedDict
for row in rows:
    assert_type(row["name"], str)
    assert_type(row["id"], int)

# Connection method with typed result
rows2 = db.query("SELECT * FROM users", result=UserRow)
assert_type(rows2, list[UserRow])
