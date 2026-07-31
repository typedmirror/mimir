def check_none(x):
    # L008: comparison to None should use 'is' not '=='
    if x == None:  # E[L008]: comparison to None using '=='
        return True
    return False
