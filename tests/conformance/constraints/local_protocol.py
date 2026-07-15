# Local variable protocol inference (§3.6 scope expansion)
# Unknown local constrained via method usage to str (from method table).

def make_thing():
    pass  # returns Unknown

def process():
    obj = make_thing()
    upper = obj.upper()    # obj constrained to str (method table match)
    stripped = obj.strip()  # reinforces str constraint
    return upper

result: int = process()  # E[T001]: Incompatible types
