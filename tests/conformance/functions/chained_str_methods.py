from typing import assert_type

# Chained string method calls
def clean_text(s: str) -> str:
    return s.strip().lower().replace(" ", "_")

r = clean_text("  Hello World  ")
assert_type(r, str)
