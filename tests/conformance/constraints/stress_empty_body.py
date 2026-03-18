# Stress: empty function body — no constraints, no return

def noop(x):
    pass

def stub(x, y, z):
    ...

# Should not crash. Return type is None.
noop(42)
stub(1, "a", [])
