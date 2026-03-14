"""mimir.db transaction type checking."""
from typing import assert_type
from mimir.db import connect, transaction, Transaction

db = connect("sqlite:///app.db")

tx = transaction(db)
assert_type(tx, Transaction)

# Transaction methods
tx.commit()
tx.rollback()
