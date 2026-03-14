# Backward inference: .decode() exists on bytes → data: bytes

def to_str(data):
    result = data.decode()
    x: int = data  # E: Incompatible types
