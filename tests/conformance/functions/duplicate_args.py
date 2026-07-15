def greet(name: str, greeting: str) -> str:
    return greeting + name

greet("alice", name="bob")  # E[T004]: duplicate argument
greet("alice", "hi")
greet(name="alice", greeting="hi")
