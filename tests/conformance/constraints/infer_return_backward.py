# Combined: backward param inference + return type inference

from typing import assert_type

def process(data):
    lines = data.split("\n")
    return len(lines)

# Backward inference resolves data → str
# Return type inferred as int from len()
# This tests that both work together
x: str = process("a")  # E: Incompatible types
