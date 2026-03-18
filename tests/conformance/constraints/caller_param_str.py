# Caller→param inference: f("hello") → param is str, body usage validates

def process(data):
    lines = data.split("\n")
    return len(lines)

# Caller provides str, body usage (.split) confirms
count: str = process("hello\nworld")  # E: Incompatible types
