# type[X] annotation — class object parameter

class Animal:
    pass

class Dog(Animal):
    pass

def create(cls: type[Animal]) -> Animal:
    return cls()

create(Dog)    # OK — Dog is subclass of Animal
create(int)    # E: Incompatible argument type
