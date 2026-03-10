# Method call results flow into assignments
s: str = "hello"

bad1: int = s.upper()  # E
bad2: str = s.find("x")  # E
bad3: bool = s.replace("h", "j")  # E
