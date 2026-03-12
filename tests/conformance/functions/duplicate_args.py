def greet(name: str, greeting: str) -> str:
    return greeting + name

greet("alice", name="bob")  # E: duplicate argument
greet("alice", "hi")
greet(name="alice", greeting="hi")
