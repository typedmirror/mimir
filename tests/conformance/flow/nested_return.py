# Nested control flow return checking
def nested(x: int) -> str:
    if x > 0:
        if x > 10:
            return "big"
        else:
            return "small"
    else:
        return "negative"

# Bad nested return
def bad_nested(x: int) -> str:
    if x > 0:
        return "positive"
    return 42  # E[T003]
