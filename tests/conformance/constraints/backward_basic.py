# Backward inference: method usage constrains parameter type

def process(data):
    lines = data.split("\n")
    return len(lines)

x: int = process("hello\nworld")
