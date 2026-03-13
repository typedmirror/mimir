# Use before definition
y = x  # E

# Variable from inner scope not accessible
def f() -> None:
    inner_var = 42

z = inner_var  # E
