# Local variable constraint inference (§3.1-3.2 scope expansion)
# Constraints collected on locals with TYPE_UNKNOWN, not just params.

def get_data():
    pass  # returns Unknown

def process():
    data = get_data()
    lines = data.split("\n")  # data constrained to str via Has_Method("split")
    return lines

result: int = process()  # E: Incompatible types
