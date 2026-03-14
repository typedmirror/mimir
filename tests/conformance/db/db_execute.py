"""mimir.db execute returns int (affected rows)."""
from typing import assert_type
from mimir.db import connect, execute

db = connect("sqlite:///app.db")

# Execute with params — returns affected row count
count = execute(db, "DELETE FROM users WHERE id = ?", params=[42])
assert_type(count, int)

# Execute without params
count2 = execute(db, "CREATE TABLE test (id int)")
assert_type(count2, int)
