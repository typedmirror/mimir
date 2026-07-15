"""Test mimir.crypt misuse detection."""
from mimir.crypt import encrypt, decrypt, hash, token

key = token.bytes(32)

# CRYPT001: ECB mode is insecure
ct = encrypt.aes_ecb(key, b"data")  # E[CRYPT001]: CRYPT001
pt = decrypt.aes_ecb(key, ct)  # E[CRYPT001]: CRYPT001

# CRYPT002: Weak hash for passwords (warning severity — verified via mimir check output)
h1 = hash.md5(b"password")
h2 = hash.sha1(b"password")

# CRYPT003: Short token (warning severity — verified via mimir check output)
short_key = token.bytes(8)
short_url = token.urlsafe(4)

# Safe patterns — no errors expected
safe_ct = encrypt.aes_gcm(key, b"data")
safe_ct2 = encrypt.aes_cbc(key, b"data")
safe_hash = hash.bcrypt("password")
safe_hash2 = hash.sha256(b"data")
safe_key = token.bytes(32)
safe_url = token.urlsafe(32)
