"""Concurrency: CPU-bound work in threads (CONC003)"""

import threading

def compute_heavy(data):
    return sum(x * x for x in range(10_000_000))

# CONC003: CPU-bound work in threads
t = threading.Thread(target=compute_heavy)

def io_work():
    pass

# CONC003 also fires here (conservative heuristic)
t2 = threading.Thread(target=io_work)
