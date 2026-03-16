import hashlib
import hmac

def test_hashlib_str():
    password: str = "secret"
    hashlib.sha256(password)  # ENC001  # E

def test_hashlib_bytes_ok():
    data: bytes = b"hello"
    hashlib.sha256(data)  # OK

def test_hashlib_new_str():
    password: str = "secret"
    hashlib.new("sha256", password)  # ENC001  # E

def test_hmac_str():
    key: str = "mykey"
    msg: str = "data"
    hmac.new(key, msg, "sha256")  # ENC001  # E
