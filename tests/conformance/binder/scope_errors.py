# Binder scope errors (B002, B004)
nonlocal x    # E[B002]  — B002: nonlocal at module level

def conflict1():
    global y
    nonlocal y    # E[B004]  — B004: both global and nonlocal

def conflict2():
    nonlocal z
    global z      # E[B004]  — B004: both global and nonlocal
