"""Taint analysis: SQL injection (SEC012)"""

cursor = None  # simulate a DB cursor

# Tainted query via f-string
name = input("Name: ")
query = f"SELECT * FROM users WHERE name = '{name}'"
cursor.execute(query)   # SEC012: input() → f-string → execute()

# Parameterized query — should NOT flag
safe_name = input("Name: ")
cursor.execute("SELECT * FROM users WHERE name = ?", (safe_name,))  # OK — parameterized

# Literal query — should NOT flag
cursor.execute("SELECT 1")  # OK — literal, never tainted
