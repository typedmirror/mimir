# Closure and nonlocal patterns — should produce zero diagnostics

def counter():
    count = 0
    def increment():
        nonlocal count
        count += 1
        return count
    return increment

def multi_level():
    x = 1
    def level1():
        y = 2
        def level2():
            nonlocal y
            y += 1
            return x + y  # x from counter enclosing, y from level1
        return level2()
    return level1()

def decorator_scope():
    def my_decorator(func):
        def wrapper(*args, **kwargs):
            return func(*args, **kwargs)
        return wrapper

    @my_decorator
    def decorated():
        return 42
    return decorated()

def closure_over_loop_var():
    funcs = []
    for i in range(5):
        def make_fn(val):
            return lambda: val
        funcs.append(make_fn(i))
    return funcs

def walrus_operator():
    if (n := 10) > 5:
        return n
    return 0

def nested_comprehension():
    matrix = [[1, 2, 3], [4, 5, 6]]
    flat = [x for row in matrix for x in row]
    return flat
