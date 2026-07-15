# Backward inference: .decode() exists on bytes → data: bytes

def to_str(data):
    result = data.decode()
    x: int = data  # E[T001]: Incompatible types
