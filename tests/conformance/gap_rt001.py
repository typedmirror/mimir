"""RT001: potential reference cycle (info-severity — marker-less; the gate asserts it fires)."""

class Node:
    def __init__(self):
        self.parent: object = None
        self.child: object = None

    def attach(self, other):
        self.child = other
        other.parent = self  # RT001: self assigned to another object's attribute
