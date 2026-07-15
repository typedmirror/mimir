"""Concurrency: non-atomic compound assignment (CONC004)"""

import threading

counter = 0

def increment():
    global counter
    counter += 1     # E[CONC004]

def no_global():
    local = 0
    local += 1       # OK — not a global variable

def no_threading_import():
    # This function is in a file that DOES import threading,
    # but has no global declaration, so no CONC004 fires
    x = 10
    x += 1           # OK — no global declaration
