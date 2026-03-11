# Forward reference / string annotation conformance

from typing import assert_type

# Class defined first, then referenced as string annotation
class Node:
    val: int
    def __init__(self, val: int):
        self.val = val

# String annotation referring to already-defined class
def make_node() -> "Node":
    return Node(1)

n = make_node()
assert_type(n, Node)

# String annotation for built-in types
x: "int" = 10
assert_type(x, int)

y: "str" = "hello"
assert_type(y, str)

z: "float" = 3.14
assert_type(z, float)

# String annotation in function parameter
def process(item: "Node") -> "int":
    return item.val

assert_type(process(Node(5)), int)
