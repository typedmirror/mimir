"""Test mimir.crypt sign namespace types."""
from typing import assert_type
from mimir.crypt import sign, token

key = token.bytes(32)
message = b"important data"

# HMAC signing returns bytes
sig = sign.hmac_sha256(key, message)
assert_type(sig, bytes)

sig2 = sign.hmac_sha512(key, message)
assert_type(sig2, bytes)

# Ed25519 signing returns bytes
sig3 = sign.ed25519(key, message)
assert_type(sig3, bytes)
