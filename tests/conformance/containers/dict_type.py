# dict[K,V] type inference and checking conformance

# Annotated dicts — no errors
ages: dict[str, int] = {"alice": 30, "bob": 25}

# Assignment mismatches
bad1: dict[str, int] = {1: "a"}   # E
bad2: dict[int, str] = {"a": 1}   # E
