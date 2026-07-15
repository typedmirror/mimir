# Use before definition
y = x  # E[B001]

# Variable from inner scope not accessible
def f() -> None:
    inner_var = 42

z = inner_var  # E[B001]
