# §3.5: TypedDict inference from param usage — x["key"] = val → TypedDict

def set_name(config):
    config["name"] = "Alice"
    config["age"] = 30

# config used with string key assignments → TypedDict-like
# The constraint engine synthesizes TypedDict{name: str, age: int}
set_name({"name": "Bob", "age": 25})
