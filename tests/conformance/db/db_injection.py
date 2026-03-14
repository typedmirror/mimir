"""mimir.db SQL injection detection (DB001) and schema validation (DB002)."""
from mimir.db import connect, query, execute

db = connect("sqlite:///app.db")
uid = 42
name = "alice"

# f-string in query SQL arg — DB001
query(db, f"SELECT * FROM users WHERE id = {uid}")  # E: unsafe SQL construction

# String concatenation in query SQL arg — DB001
query(db, "SELECT * FROM users WHERE id = " + str(uid))  # E: unsafe SQL construction

# .format() in query SQL arg — DB001
query(db, "SELECT * FROM users WHERE id = {}".format(uid))  # E: unsafe SQL construction

# f-string in execute SQL arg — DB001
execute(db, f"DELETE FROM users WHERE name = '{name}'")  # E: unsafe SQL construction

# Connection method with f-string — DB001
db.query(f"SELECT * FROM users WHERE id = {uid}")  # E: unsafe SQL construction

# Connection method with concatenation — DB001
db.execute("DELETE FROM users WHERE id = " + str(uid))  # E: unsafe SQL construction

# Invalid result schema — DB002
query(db, "SELECT * FROM users", result=int)  # E: Invalid query result schema

# Parameterized — safe, no DB001
query(db, "SELECT * FROM users WHERE id = ?", params=[uid])
execute(db, "DELETE FROM users WHERE name = ?", params=[name])

# Connection method with literal — safe
db.query("SELECT * FROM users")
db.execute("CREATE TABLE test (id int)")

# Literal string — safe
query(db, "SELECT * FROM users")
