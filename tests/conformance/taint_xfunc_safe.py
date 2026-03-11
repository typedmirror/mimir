"""Cross-function taint: safe patterns (no false positives).

These patterns must NOT trigger any taint violations.
"""

cursor = None  # simulate DB cursor

# Safe 1: function doesn't propagate — constant return
def get_config():
    return {"timeout": 30}

def handler_safe_config():
    config = get_config()
    cursor.execute(config)  # NOT a violation — get_config returns constant

# Safe 2: function propagates but no tainted arg at call site
def build_greeting(name):
    return f"Hello, {name}!"

def handler_safe_greeting():
    msg = build_greeting("Alice")
    cursor.execute(msg)  # NOT a violation — arg is a literal

# Safe 3: sanitizer breaks taint chain
def get_data():
    return input("Enter: ")

def handler_safe_sanitized():
    data = get_data()
    safe = int(data)
    cursor.execute(safe)  # NOT a violation — int() sanitizes
