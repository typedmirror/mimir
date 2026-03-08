# Exception CFG test — try/except/finally patterns
# Expected: 0 F001, 0 guards

# Basic try/except
try:
    x = int("42")
except ValueError:
    x = 0

# Try/except/else
try:
    y = int("99")
except ValueError:
    y = -1
else:
    y = y + 1

# Try/except/finally
try:
    f = open("test.txt")
except FileNotFoundError:
    f = None
finally:
    cleanup = True

# Try with multiple handlers
try:
    result = int("abc")
except ValueError:
    result = -1
except TypeError:
    result = -2

# Nested try
try:
    try:
        inner = 1
    except Exception:
        inner = 0
except Exception:
    outer = 0

# Try/except with as
try:
    bad = 1 / 0
except ZeroDivisionError as e:
    error_msg = str(e)

# With statement
with open("file.txt") as f:
    content = f.read()
