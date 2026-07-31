"""
RT005: Unreliable __del__ with side-effect calls.
Note: RT005 is Info-level and verified via `mimir check`, not conform.
"""

class FileHandle:
    def __init__(self, path: str) -> None:
        self.file = open(path, 'r')

    def __del__(self) -> None:
        self.file.close()
