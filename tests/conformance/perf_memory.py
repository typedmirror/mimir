"""Performance analysis: memory and caching anti-patterns.

PERF003 — open().read() reads entire file into memory
PERF004 — unhashable @lru_cache parameter

These are .Performance severity diagnostics, not .Error.
No required markers — this file verifies no false positive .Error diagnostics.
Actual PERF rule detection is verified via 'mimir perf'.
"""

# --- PERF003: open().read() ---

# Detection: chained open().read()
data = open("file.txt").read()  # E[PERF003]

# Detection: chained open().readlines()
lines = open("file.txt").readlines()  # E[PERF003]

# Safe: separate variable (not chained call pattern)
f = open("file.txt")


# --- PERF004: unhashable lru_cache param ---

from functools import lru_cache, cache

# Detection: list param with @lru_cache
@lru_cache
def process(data: list):  # E[PERF004]
    return sum(data)

# Detection: dict param with @lru_cache(maxsize=128)
@lru_cache(maxsize=128)
def transform(items: dict):  # E[PERF004]
    return len(items)

# Detection: set param with @cache
@cache
def unique(values: set):  # E[PERF004]
    return len(values)

# Safe: hashable param types
@lru_cache
def compute(n: int):
    return n * n

@lru_cache
def lookup(key: str):
    return key.upper()

@lru_cache
def process_tuple(data: tuple):
    return len(data)

# Safe: no annotation (can't tell type)
@lru_cache
def unknown_type(data):
    return data
