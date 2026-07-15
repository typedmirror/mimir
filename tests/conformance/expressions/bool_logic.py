# Boolean operators (and/or)
a: bool = True and False
b: bool = True or False
x: int = 1 or 2       # int or int -> int
y: str = "a" or "b"   # str or str -> str
bad: int = "a" and "b"  # E[T001]
