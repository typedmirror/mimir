from typing import TypedDict

# Class syntax
class Movie(TypedDict):
    name: str
    year: int

m: Movie = Movie(name="Blade Runner", year=1982)
x: str = m["name"]
y: int = m["year"]
z = m["invalid"]  # E[T001]

# Functional syntax
Point = TypedDict("Point", {"x": int, "y": int})
p: Point = Point(x=1, y=2)
px: int = p["x"]
pz = p["missing"]  # E[T001]
