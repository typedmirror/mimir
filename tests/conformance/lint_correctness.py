import os          # L001: unused import  # E[L001]
import sys         # used below

x = 1              # L002: unused variable  # E[L002]
y = 2              # used below
print(y, sys.argv)

def foo(items=[]):  # L003: mutable default argument  # E[L003]
    pass

s = f"hello"       # L004: f-string without placeholders  # E[L002|L004]

try:
    pass
except:            # L005: bare except  # E[L005]
    pass

assert(True, "msg")  # L006: assert with tuple  # E[L006]
