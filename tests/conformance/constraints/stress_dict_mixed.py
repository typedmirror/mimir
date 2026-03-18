# Stress: dict literal + key assignment — should merge into TypedDict

d = {"name": "Alice"}
d["age"] = 30
d["active"] = True

# Should be TypedDict{name: str, age: int, active: bool}
# Dict literal starts as dict[str, str], key assignment should evolve it
