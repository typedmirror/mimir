"""T1 regression: sibling module deliberately named like a stdlib module.
sys.path[0] parity requires THIS file to shadow the stdlib json stubs."""


class Widget:
    def __init__(self, name: str) -> None:
        self.name = name
