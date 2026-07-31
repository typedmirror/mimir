"""Test P001: parse-drop warning for unparseable statement syntax."""

def valid_function():
    """A normal function."""
    x = 1
    return x

# Unparseable syntax: bare operator at statement level
# Parser will skip this and emit P001
**

def another_function():
    """Another normal function after the parse drop."""
    y = 2
    return y
