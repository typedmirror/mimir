"""mimir.db connect type checking."""
from typing import TypedDict, assert_type
from mimir.db import connect, Connection

db = connect("sqlite:///app.db")
assert_type(db, Connection)

# Connection attributes
db.close()
db.in_transaction
