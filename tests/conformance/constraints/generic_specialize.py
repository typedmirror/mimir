# §3.4: Usage-based generic specialization
# Per-call-site return types for unannotated generic functions

def first(items):
    return items[0]

# Multiple callers with different types — establishes generic behavior
names = first(["alice", "bob"])
ages = first([25, 30])

# Correctly typed — specialized per call site, should NOT error
x: str = first(["hello"])
y: int = first([1, 2, 3])

# Incorrectly typed — specialized return doesn't match declaration
z: int = first(["hello"])  # E[T001]: Incompatible types
w: str = first([1, 2, 3])  # E[T001]: Incompatible types
