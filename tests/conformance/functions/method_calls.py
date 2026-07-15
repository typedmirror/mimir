# Method call results flow into assignments
s: str = "hello"

bad1: int = s.upper()  # E[T001]
bad2: str = s.find("x")  # E[T001]
bad3: bool = s.replace("h", "j")  # E[T001]
