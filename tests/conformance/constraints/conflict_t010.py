# T010: Body/caller type conflict — Warning severity

def process(x):
    lines = x.split("\n")
    return len(lines)

# Body says x.split() -> str, but caller says int -> T010 warning
result = process(42)
