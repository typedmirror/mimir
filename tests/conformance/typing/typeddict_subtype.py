from typing import TypedDict, Dict

class Movie(TypedDict):
    name: str
    year: int

# TypedDict assignable to Dict[str, ...]
m = Movie(name="Blade Runner", year=1982)
d: Dict[str, str] = m

# TypedDict field access
name: str = m["name"]
year: int = m["year"]

# Wrong field type in assignment
bad: int = m["name"]  # E
