# Backward inference: .encode() exists on str → data: str

def to_bytes(data):
    result = data.encode()
    x: int = data  # E[T001]: Incompatible types
