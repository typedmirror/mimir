# Match/case: basic patterns, variable binding, exhaustiveness

# Variable binding from match subject
def process(cmd: str) -> int:
    match cmd:
        case "quit":
            return 0
        case "help":
            return 1
        case other:
            x: str = other
            return -1

# As pattern binding
def describe(val: int) -> str:
    match val:
        case 1 | 2 | 3 as small:
            return f"small: {small}"
        case _:
            return "big"

# Non-exhaustive match (no wildcard) — MATCH001 is a warning, not caught by conformance
# F002 fires because not all paths return
def risky(x: int) -> int:  # E[F002]
    match x:
        case 1:
            return 1
        case 2:
            return 2

# Exhaustive match (wildcard present) — no warning
def safe(x: int) -> str:
    match x:
        case 1:
            return "one"
        case _:
            return "other"
