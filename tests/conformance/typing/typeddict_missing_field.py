from typing import TypedDict

class Movie(TypedDict):
    name: str
    year: int

# Missing required field
m1 = Movie(name="Blade Runner")  # E[T004]

# All fields provided — ok
m2 = Movie(name="Alien", year=1979)
