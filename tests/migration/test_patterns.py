"""Test migration detection for code patterns."""
from collections import OrderedDict, MutableMapping

# MIG005: isinstance with tuple
def check(x):
    if isinstance(x, (str, int, float)):
        pass
    if issubclass(type(x), (list, tuple)):
        pass

# MIG006: OrderedDict
od = OrderedDict()

# MIG007: collections ABCs (detected at import level)
# Already imported MutableMapping above

# MIG008: Long if/elif chain
def dispatch(cmd):
    if cmd == "start":
        pass
    elif cmd == "stop":
        pass
    elif cmd == "restart":
        pass
    elif cmd == "status":
        pass
