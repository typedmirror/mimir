# Basic scoping patterns — should produce zero diagnostics

x = 10
y: int = 20

def simple_function(a, b):
    c = a + b
    return c

def nested_scope():
    outer = 1
    def inner():
        return outer  # closure over enclosing function
    return inner()

def global_usage():
    global x
    x = 42
    return x

def parameters(pos_only, /, normal, *, kw_only, **kwargs):
    return pos_only + normal + kw_only

def for_loop():
    result = []
    for i in range(10):
        result.append(i)
    return result

def with_statement():
    with open("test") as f:
        data = f.read()
    return data

def augmented_assign():
    count = 0
    count += 1
    return count

def tuple_unpack():
    a, b = 1, 2
    (c, d) = (3, 4)
    [e, f] = [5, 6]
    return a + b + c + d + e + f

class MyClass:
    class_var = 10

    def method(self):
        return self.class_var

    def other_method(self):
        x = self.class_var
        return x

def comprehensions():
    squares = [x**2 for x in range(10)]
    evens = {x for x in range(20) if x % 2 == 0}
    mapping = {k: v for k, v in enumerate(range(5))}
    gen = sum(x for x in range(100))
    return squares, evens, mapping, gen

def lambda_usage():
    fn = lambda x, y: x + y
    return fn(1, 2)

def try_except():
    try:
        result = 1 / 0
    except ZeroDivisionError as e:
        result = 0
    finally:
        pass
    return result

import os
from os.path import join, exists

def use_imports():
    return join("a", "b")
