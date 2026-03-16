# Match/case: class pattern narrowing and type errors

class Point:
    x: int
    y: int

class Circle:
    radius: float

# Class pattern binds attrs with correct types
def area(shape) -> str:
    match shape:
        case Point(x=px, y=py):
            bad: str = px  # E: int not assignable to str
            return f"({px},{py})"
        case Circle(radius=r):
            return f"r={r}"
        case _:
            return "?"
