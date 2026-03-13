from typing import assert_type

# object is the universal base type — accepts anything
a: object = 42
b: object = "hello"
c: object = [1, 2, 3]
d: object = None
e: object = 3.14
f: object = True

# Assigning non-object to object is fine
g: object = (1, 2, 3)
