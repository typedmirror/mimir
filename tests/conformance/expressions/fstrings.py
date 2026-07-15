# F-strings always produce str
name: str = "world"
x: str = f"hello {name}"
y: str = f"{1 + 2}"
z: str = f"{True}"
bad: int = f"hello"  # E[T001]
