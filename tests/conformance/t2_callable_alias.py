# T2 regression: module-level Callable type aliases used as parameter
# annotations mean the CALLABLE ITSELF, not its return type.
from typing import Callable, Dict, List


class Event:
    def __init__(self, name: str) -> None:
        self.name = name


Handler = Callable[[Event], None]


class Bus:
    def __init__(self) -> None:
        self._handlers: Dict[str, List[Handler]] = {}

    def on(self, event_name: str, handler: Handler) -> None:
        self._handlers.setdefault(event_name, []).append(handler)


def wire() -> None:
    bus = Bus()

    def on_login(event: Event) -> None:
        print(event.name)

    # Matching handler — must NOT be flagged (was the FP)
    bus.on("user.login", on_login)

    # Non-callable for a callable param — real bug, must fire
    bus.on("user.logout", 42)  # E[T002]
