# Tests for SAF001 (exception-swallowed) and SAF002 (overly-broad-except)
# Verified via: mimir safety tests/conformance/safety/error_handling.py

# SAF001: exception silently swallowed
try:
    x = int("abc")
except ValueError:
    pass  # SAF001

# SAF001: nested try
def process():
    try:
        data = open("f.txt")
    except IOError:
        pass  # SAF001

# SAF002: overly broad except
try:
    y = 1 / 0
except Exception:  # SAF002
    y = 0

# SAF002: BaseException
try:
    z = 1
except BaseException:  # SAF002
    z = 0

# OK: specific exception with handling
try:
    a = int("x")
except ValueError as e:
    print(e)

# OK: re-raise
try:
    b = 1
except TypeError:
    raise
