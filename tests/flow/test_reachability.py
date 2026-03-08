# Reachability test — dead code after terminators
# Expected: 4 F001 warnings

def after_return():
    x = 1
    return x
    y = 2  # F001: unreachable

def after_raise():
    raise ValueError("bad")
    cleanup = True  # F001: unreachable

def after_break():
    for i in range(10):
        if i == 5:
            break
            never = True  # F001: unreachable

def after_continue():
    for i in range(10):
        if i % 2 == 0:
            continue
            skipped = True  # F001: unreachable

# These should NOT trigger F001:
def ok_if_return():
    if True:
        return 1
    else:
        return 2

def ok_try_return():
    try:
        return 1
    except Exception:
        return 2
