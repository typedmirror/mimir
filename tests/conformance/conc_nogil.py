"""CONC006: free-threaded unsafe — global assignment without lock"""
from threading import Thread

counter = 0

def increment():
    global counter
    counter = counter + 1
    # CONC006: assignment to global not thread-safe without GIL
