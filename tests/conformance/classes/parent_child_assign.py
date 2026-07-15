from typing import assert_type

class Vehicle:
    def __init__(self, speed: int) -> None:
        self.speed = speed

class Car(Vehicle):
    def __init__(self, speed: int, doors: int) -> None:
        self.speed = speed
        self.doors = doors

class Truck(Vehicle):
    def __init__(self, speed: int, payload: float) -> None:
        self.speed = speed
        self.payload = payload

# Child assignable to parent
v: Vehicle = Car(100, 4)

# Sibling not assignable
bad: Truck = Car(100, 4)  # E[T001]
