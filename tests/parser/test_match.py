"""Test match/case patterns (Python 3.10+)."""

def process(command):
    match command:
        case "quit":
            return 0
        case "hello" | "hi":
            print("Hello!")
        case ["go", direction]:
            print(f"Going {direction}")
        case {"action": action, **rest}:
            print(f"Action: {action}")
        case Point(x=0, y=0):
            print("Origin")
        case [*items]:
            print(f"Got items: {items}")
        case _ as other:
            print(f"Unknown: {other}")
