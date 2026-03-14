# Tests for SAF006 (regex-catastrophic-backtracking)
# Verified via: mimir safety tests/conformance/safety/regex_safety.py

import re

def test_regex():
    # SAF006: nested quantifiers — classic ReDoS
    re.compile(r"(a+)+b")  # SAF006  # E

    # SAF006: another pattern
    re.search(r"(x+x+)+y", "test")  # SAF006  # E

    # OK: normal patterns
    re.compile(r"\d+")
    re.match(r"[a-z]+@[a-z]+\.[a-z]+", "test")
    re.findall(r"(\w+)", "hello world")
