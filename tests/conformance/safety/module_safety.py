# Tests for SAF003 (import-side-effect), SAF004 (monkey-patch), SAF005 (global-state-mutation)
# Verified via: mimir safety tests/conformance/safety/module_safety.py

import json
import os

# Dummy definitions so binder doesn't flag undefined names
def connect_to_database(): pass
def setup_logging(): pass
class Config: pass

# SAF003: function call at module level
db = connect_to_database()  # SAF003  # E

# SAF003: bare call at module level
setup_logging()  # SAF003  # E

# OK: safe builtins at module level
x = dict()
y = list()
z = int(42)
name = str("hello")

# OK: class constructor (capitalized)
config = Config()

# SAF004: monkey-patching
json.dumps = lambda x: x  # SAF004  # E

# SAF005: global state mutation
_cache = {}
_items = []

def get_user(uid):
    _cache[uid] = "found"  # SAF005  # E

def add_item(item):
    _items.append(item)  # SAF005  # E
