# Narrowing guards test — isinstance, is None, truthiness
# Expected: 0 F001, 6+ guards

x = None
y = None
z = None

# isinstance guard
if isinstance(x, int):
    a = x + 1

# is None guard
if y is None:
    y = 0

# is not None guard
if z is not None:
    z_len = len(z)

# Truthiness guard
val = None
if val:
    used = val

# Not truthiness guard (negation)
flag = None
if not flag:
    default_flag = True

# type() is guard
obj = None
if type(obj) is int:
    typed = obj
