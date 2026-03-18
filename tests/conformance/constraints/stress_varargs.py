# Stress: *args/**kwargs — variadic params shouldn't crash constraint engine

def variadic(*args):
    return len(args)

def keyword_heavy(**kwargs):
    return kwargs

variadic(1, 2, 3)
keyword_heavy(a=1, b="two")
