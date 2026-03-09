from models import User

u = User("alice")
x: str = u.name       # OK — name is str
y: int = u.name       # E  — str not assignable to int
z: str = u.greet()    # OK — greet returns str
w: int = u.greet()    # E  — str not assignable to int
