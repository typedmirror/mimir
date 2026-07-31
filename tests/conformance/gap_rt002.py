# Test RT002: object construction inside loop

class Handler:
    def __init__(self, name: str) -> None:
        self.name = name

def process_items(items: list[str]) -> None:
    handlers = []
    for item in items:
        handler = Handler(item)
        handlers.append(handler)
