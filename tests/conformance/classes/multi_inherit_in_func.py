from typing import assert_type

class Flyer:
    def fly(self) -> str:
        return "flying"

class Swimmer:
    def swim(self) -> str:
        return "swimming"

class Duck(Flyer, Swimmer):
    pass

# Multiple inheritance class construction in function
def test_duck():
    d = Duck()
    assert_type(d, Duck)
