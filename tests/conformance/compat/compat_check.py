def test_match():
    x = 42
    match x:  # COMPAT001: match/case requires 3.10+  # E[COMPAT001]
        case 42:
            pass
        case _:
            pass
