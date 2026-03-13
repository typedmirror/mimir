from typing import assert_type

# Nested dict construction in function
def build_config() -> dict[str, dict[str, int]]:
    return {"db": {"port": 5432, "timeout": 30}}
