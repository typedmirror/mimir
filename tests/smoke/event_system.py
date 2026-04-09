"""Smoke test: Event-driven system with pub/sub, generic handlers, decorators.
Tests: Generic classes, Callable types, decorator patterns, dict operations,
protocol-like structural typing.
"""
from typing import TypeVar, Generic, Callable, List, Dict, Optional, Any

T = TypeVar('T')

# ---- Event types ----

class Event:
    def __init__(self, name: str, data: Any) -> None:
        self.name = name
        self.data = data
        self.handled: bool = False

class UserEvent(Event):
    def __init__(self, user_id: int, action: str) -> None:
        super().__init__(f"user.{action}", {"user_id": user_id})
        self.user_id = user_id
        self.action = action

class SystemEvent(Event):
    def __init__(self, component: str, level: str, message: str) -> None:
        super().__init__(f"system.{component}", {"level": level, "message": message})
        self.component = component
        self.level = level
        self.message = message

# ---- Event bus ----

Handler = Callable[[Event], None]

class EventBus:
    def __init__(self) -> None:
        self._handlers: Dict[str, List[Handler]] = {}
        self._middleware: List[Callable[[Event], Optional[Event]]] = []

    def on(self, event_name: str, handler: Handler) -> None:
        if event_name not in self._handlers:
            self._handlers[event_name] = []
        self._handlers[event_name].append(handler)

    def use(self, middleware: Callable[[Event], Optional[Event]]) -> None:
        self._middleware.append(middleware)

    def emit(self, event: Event) -> None:
        # Run middleware chain
        current: Optional[Event] = event
        for mw in self._middleware:
            if current is None:
                return
            current = mw(current)

        if current is None:
            return

        # Dispatch to handlers
        handlers = self._handlers.get(current.name, [])
        for handler in handlers:
            handler(current)
            if current.handled:
                break

        # Wildcard handlers
        wildcard = self._handlers.get("*", [])
        for handler in wildcard:
            handler(current)

# ---- Typed event store ----

class EventStore(Generic[T]):
    def __init__(self) -> None:
        self._events: List[T] = []

    def append(self, event: T) -> None:
        self._events.append(event)

    def last(self) -> Optional[T]:
        if len(self._events) == 0:
            return None
        return self._events[-1]

    def count(self) -> int:
        return len(self._events)

    def filter(self, predicate: Callable[[T], bool]) -> List[T]:
        return [e for e in self._events if predicate(e)]

# ---- Middleware ----

def logging_middleware(event: Event) -> Optional[Event]:
    """Log all events."""
    _ = f"[LOG] {event.name}: {event.data}"
    return event

def rate_limit_middleware(max_per_second: int) -> Callable[[Event], Optional[Event]]:
    """Create a rate-limiting middleware."""
    count = 0

    def middleware(event: Event) -> Optional[Event]:
        nonlocal count
        count += 1
        if count > max_per_second:
            return None  # Drop event
        return event

    return middleware

# ---- Main ----

def main() -> None:
    bus = EventBus()
    store: EventStore[Event] = EventStore()

    # Register middleware
    bus.use(logging_middleware)
    bus.use(rate_limit_middleware(100))

    # Register handlers
    def on_user_login(event: Event) -> None:
        store.append(event)

    def on_system_error(event: Event) -> None:
        store.append(event)
        event.handled = True

    bus.on("user.login", on_user_login)
    bus.on("system.error", on_system_error)

    # Emit events
    bus.emit(UserEvent(user_id=1, action="login"))
    bus.emit(UserEvent(user_id=2, action="login"))
    bus.emit(SystemEvent(component="db", level="error", message="connection lost"))

    # Query store
    errors = store.filter(lambda e: isinstance(e, SystemEvent))
    last = store.last()
    total = store.count()

if __name__ == "__main__":
    main()
