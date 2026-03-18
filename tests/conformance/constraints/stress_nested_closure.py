# Stress: nested functions with closures — outer var captured

def make_adder(x):
    def add(y):
        return x + y
    return add

adder = make_adder(10)
