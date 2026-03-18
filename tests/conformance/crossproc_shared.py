"""PROC001: shared mutable state in multiprocessing"""
import multiprocessing

shared_dict = {}

def worker(key, value):
    shared_dict[key] = value

pool = multiprocessing.Pool()
pool.map(worker, [(1, "a"), (2, "b")])  # E
