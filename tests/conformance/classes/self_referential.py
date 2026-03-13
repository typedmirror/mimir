from typing import assert_type

# Self-referential class using forward reference
class TreeNode:
    value: int
    left: "TreeNode"
    right: "TreeNode"

    def __init__(self, value: int) -> None:
        self.value = value

n = TreeNode(1)
assert_type(n, TreeNode)
assert_type(n.value, int)
assert_type(n.left, TreeNode)
