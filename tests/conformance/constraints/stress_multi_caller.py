# Stress: multiple callers with different types → union
# f(42) + f("hello") should infer x as int | str

def identity(x):
    return x

a = identity(42)
b = identity("hello")
