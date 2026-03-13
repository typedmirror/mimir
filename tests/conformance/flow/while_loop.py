# While loop unreachable after break
def check(x: int) -> int:
    while True:
        if x > 0:
            return x
        break
    return 0

# While with return — no missing return
def good(x: int) -> int:
    while x > 0:
        return x
    return 0
