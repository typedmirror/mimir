# Backward inference: data.split("\n") → data: str
# Then assigning data to int should error inside the function

def process(data):
    lines = data.split("\n")
    x: int = data  # E[T001]: Incompatible types
