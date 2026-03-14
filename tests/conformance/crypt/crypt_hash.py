"""Test mimir.crypt hash namespace types."""
from typing import assert_type
from mimir.crypt import hash, verify

# Password hashing returns str
hashed = hash.bcrypt("password123")
assert_type(hashed, str)

hashed2 = hash.argon2("password123")
assert_type(hashed2, str)

# Data hashing returns str
digest = hash.sha256(b"data")
assert_type(digest, str)

digest2 = hash.sha512(b"data")
assert_type(digest2, str)

digest3 = hash.sha3_256(b"data")
assert_type(digest3, str)

# Verification returns bool
valid = verify.bcrypt("password123", hashed)
assert_type(valid, bool)

valid2 = verify.argon2("password123", hashed2)
assert_type(valid2, bool)
