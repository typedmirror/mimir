"""Test mimir.crypt encrypt/decrypt namespace types."""
from typing import assert_type
from mimir.crypt import encrypt, decrypt, token

# Generate a key
key = token.bytes(32)

# Encryption returns bytes
ct = encrypt.aes_gcm(key, b"secret data")
assert_type(ct, bytes)

ct2 = encrypt.aes_cbc(key, b"secret data")
assert_type(ct2, bytes)

ct3 = encrypt.aes_ctr(key, b"secret data")
assert_type(ct3, bytes)

ct4 = encrypt.chacha20(key, b"secret data")
assert_type(ct4, bytes)

# Decryption returns bytes
pt = decrypt.aes_gcm(key, ct)
assert_type(pt, bytes)

pt2 = decrypt.aes_cbc(key, ct2)
assert_type(pt2, bytes)

pt3 = decrypt.chacha20(key, ct4)
assert_type(pt3, bytes)
