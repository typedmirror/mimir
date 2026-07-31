# Test for L011: builtin-shadow

list = [1, 2, 3]  # E[L011]: shadows builtin

def len(x):  # E[L011]: shadows builtin len
    return 5

# Reference the shadowed names
assert list[0] == 1
assert len(1) == 5
