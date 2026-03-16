def test_match():
    x = 42
    match x:  # COMPAT001: match/case requires 3.10+  # E
        case 42:
            pass
        case _:
            pass
