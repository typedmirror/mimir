# Error cases — should produce specific diagnostics

# B001: undefined name
def use_undefined():
    return undefined_variable

# B002: nonlocal at module level
# Note: this is a SyntaxError in CPython, but we report it as B002
# Commenting out because CPython's parser will reject it before we see it
# nonlocal bad_nonlocal

# B001: another undefined
def call_undefined():
    undefined_function()

# B004: global and nonlocal conflict (inside function)
def conflict():
    global x_conflict
    # nonlocal x_conflict  # would be B004, but CPython rejects this at parse time

# B001: undefined in nested scope
def outer():
    def inner():
        return totally_missing_name
    return inner
