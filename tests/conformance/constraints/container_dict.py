# Container inference: x.get(key) → x is dict

def lookup(x, key: str):
    return x.get(key)

result: int = lookup({"a": 1}, "a")  # E: Incompatible types
