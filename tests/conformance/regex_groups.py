import re

def test_numeric_group():
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", "2026-03-15")
    m.group(0)   # OK — whole match
    m.group(1)   # OK — first group
    m.group(3)   # OK — third group
    m.group(4)   # REG001  # E

def test_named_group():
    m = re.search(r"(?P<host>[\w.]+):(?P<port>\d+)", "localhost:8080")
    m.group("host")  # OK
    m.group("port")  # OK
    m.group("prot")  # REG002  # E

def test_compiled_pattern():
    pattern = re.compile(r"(\w+)\s(\w+)")
    m = pattern.match("hello world")
    m.group(2)   # OK
    m.group(3)   # REG001  # E

def test_no_groups():
    m = re.match(r"\d+", "123")
    m.group(0)   # OK — whole match
    m.group(1)   # REG001  # E

def test_named_no_match():
    m = re.match(r"(?P<year>\d{4})-(?P<month>\d{2})", "2026-03")
    m.group("day")  # REG002  # E
