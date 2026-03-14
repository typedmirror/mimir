"""Cross-function taint propagation tests.

Taint diagnostics use .Security severity, so conformance runner won't
match them as markers. These tests verify zero false positives.
Positive detection is verified via mimir audit output.
"""
import os

cursor = None  # simulate DB cursor

# Tier 1: always_tainted — function body contains a taint source
def get_input():
    return os.environ.get("USER_DATA", "")

def handler_always():
    data = get_input()
    query = f"SELECT * FROM t WHERE x = '{data}'"
    cursor.execute(query)  # SEC012 expected via mimir audit  # E

# Tier 2: propagates — param taint reaches return
def build_query(data):
    return f"SELECT * FROM t WHERE x = '{data}'"

def handler_propagates():
    data = os.environ.get("X", "")
    query = build_query(data)
    cursor.execute(query)  # SEC012 expected via mimir audit  # E

# Tier 3: multi-hop chain
def step1():
    return os.environ.get("X", "")

def step2(x):
    return x.upper()

def step3(y):
    return f"SELECT * FROM t WHERE x = '{y}'"

def handler_multihop():
    a = step1()
    b = step2(a)
    c = step3(b)
    cursor.execute(c)  # SEC012 expected via mimir audit  # E
