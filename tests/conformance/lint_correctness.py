import os          # L001: unused import
import sys         # used below

x = 1              # L002: unused variable
y = 2              # used below
print(y, sys.argv)

def foo(items=[]):  # L003: mutable default argument
    pass

s = f"hello"       # L004: f-string without placeholders

try:
    pass
except:            # L005: bare except
    pass

assert(True, "msg")  # L006: assert with tuple
