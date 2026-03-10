x: int = 1
y: str = "hello"

# Bool_Op produces union of operand types
z = x or y

bad1: int = z  # E
bad2: str = z  # E
bad3: bool = z  # E
