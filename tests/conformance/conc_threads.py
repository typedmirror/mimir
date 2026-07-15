"""Concurrency: CPU-bound work in threads (CONC003)"""

import threading

def compute_heavy(data):
    return sum(x * x for x in range(10_000_000))

t = threading.Thread(target=compute_heavy)  # E[CONC003]

def io_work():
    pass

t2 = threading.Thread(target=io_work)  # E[CONC003]
