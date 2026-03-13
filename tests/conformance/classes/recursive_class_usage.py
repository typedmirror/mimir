from typing import assert_type, Optional

class Node:
    value: int
    next: Optional["Node"]
    def __init__(self, value: int):
        self.value = value
        self.next = None

# Recursive class construction in function
def build_list(n: int) -> Node:
    head = Node(0)
    return head
