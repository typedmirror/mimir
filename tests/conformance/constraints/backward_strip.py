# Backward inference: multiple str methods → data: str

def clean(data):
    stripped = data.strip()
    upper = data.upper()
    x: int = data  # E: Incompatible types
