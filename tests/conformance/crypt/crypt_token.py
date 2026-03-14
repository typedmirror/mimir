"""Test mimir.crypt token namespace types."""
from typing import assert_type
from mimir.crypt import token

# token.bytes returns bytes
key = token.bytes(32)
assert_type(key, bytes)

# token.urlsafe returns str
api_key = token.urlsafe(32)
assert_type(api_key, str)

# token.digits returns str
otp = token.digits(6)
assert_type(otp, str)

# token.hex returns str
hex_token = token.hex(16)
assert_type(hex_token, str)
