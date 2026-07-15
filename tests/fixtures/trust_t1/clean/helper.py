"""T1 regression (clean case): sibling module with real types."""


def double(n: int) -> int:
    return n * 2


class Box:
    def __init__(self, label: str) -> None:
        self.label = label
