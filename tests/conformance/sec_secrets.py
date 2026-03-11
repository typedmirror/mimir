"""Security: secrets rules (SEC004-SEC005)"""

# SEC004 — hardcoded secret (variable name)
API_KEY = "sk-abc123def456ghi789jkl"             # SEC004
SECRET_KEY = "my-super-secret-key-12345"         # SEC004
NORMAL_STRING = "hello world"                     # OK

# SEC004 — known prefix
token_val = "ghp_xxxxxxxxxxxxxxxxxxxx"            # SEC004

# SEC005 — embedded credentials
db_url = "postgresql://admin:s3cret@prod:5432/mydb"  # SEC005
safe_url = "postgresql://localhost/mydb"               # OK — no password
