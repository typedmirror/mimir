# Fixture for MATCH002: unreachable match case after wildcard
# A wildcard pattern in match/case matches all values,
# making any subsequent cases unreachable.

def process(value: int) -> None:
    match value:
        case _:  # Wildcard matches everything
            print("default")
        case 1:  # Warning: unreachable after wildcard
            print("one")
