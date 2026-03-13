from typing import assert_type, Optional

# Complex return type annotation
def parse_pair(s: str) -> tuple[str, Optional[int]]:
    parts = s.split(":")
    return (parts[0], None)
