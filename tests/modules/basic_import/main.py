from utils import add, greet

x: int = add(1, 2)       # OK — add returns int
y: str = add(1, 2)       # E  — int not assignable to str
z: str = greet("world")  # OK — greet returns str
w: int = greet("world")  # E  — str not assignable to int
