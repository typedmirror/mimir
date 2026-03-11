"""Security: crypto rules (SEC001-SEC003)"""

import hashlib
import random

# SEC001 — weak hash
h1 = hashlib.md5(b"data")     # SEC001
h2 = hashlib.sha1(b"data")    # SEC001
h3 = hashlib.sha256(b"data")  # OK — strong hash

# SEC001 — hashlib.new with weak algo
h4 = hashlib.new("md5")       # SEC001

# SEC002 — insecure random for security value
token = random.choice("abcdef")         # SEC002
nonce = random.randint(0, 999999)        # SEC002
value = random.randint(1, 100)           # OK — not security context

# SEC003 — timing attack
password_hash = "abc123"
if password_hash == "expected":          # SEC003
    pass
