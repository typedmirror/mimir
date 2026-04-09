"""Smoke test: Async HTTP-style server with coroutines and error handling.
Tests: async/await, Optional narrowing, Union returns, dataclass-like patterns,
exception handling, generic async operations.
"""
from typing import Optional, List, Dict, Callable, Awaitable

# ---- Async primitives (mocked) ----

class Request:
    def __init__(self, method: str, path: str, body: Optional[str] = None) -> None:
        self.method = method
        self.path = path
        self.body = body
        self.headers: Dict[str, str] = {}

class Response:
    def __init__(self, status: int, body: str = "") -> None:
        self.status = status
        self.body = body
        self.headers: Dict[str, str] = {}

    def json(self, data: dict) -> "Response":
        self.body = str(data)
        self.headers["content-type"] = "application/json"
        return self

# ---- Middleware ----

Handler = Callable[[Request], Awaitable[Response]]

class Middleware:
    def __init__(self) -> None:
        self._before: List[Callable[[Request], Optional[Response]]] = []
        self._after: List[Callable[[Response], Response]] = []

    def before(self, hook: Callable[[Request], Optional[Response]]) -> None:
        self._before.append(hook)

    def after(self, hook: Callable[[Response], Response]) -> None:
        self._after.append(hook)

    def run_before(self, req: Request) -> Optional[Response]:
        for hook in self._before:
            result = hook(req)
            if result is not None:
                return result
        return None

    def run_after(self, resp: Response) -> Response:
        for hook in self._after:
            resp = hook(resp)
        return resp

# ---- Router ----

class Router:
    def __init__(self) -> None:
        self.routes: Dict[str, Dict[str, Handler]] = {}

    def add(self, method: str, path: str, handler: Handler) -> None:
        if path not in self.routes:
            self.routes[path] = {}
        self.routes[path][method] = handler

    def resolve(self, method: str, path: str) -> Optional[Handler]:
        path_routes = self.routes.get(path)
        if path_routes is None:
            return None
        return path_routes.get(method)

# ---- App ----

class App:
    def __init__(self) -> None:
        self.router = Router()
        self.middleware = Middleware()

    async def handle(self, req: Request) -> Response:
        # Run before middleware
        early = self.middleware.run_before(req)
        if early is not None:
            return early

        # Route resolution
        handler = self.router.resolve(req.method, req.path)
        if handler is None:
            return Response(404, "Not Found")

        # Execute handler with error handling
        try:
            resp = await handler(req)
        except Exception:
            return Response(500, "Internal Server Error")

        # Run after middleware
        return self.middleware.run_after(resp)

# ---- Handlers ----

async def health_check(req: Request) -> Response:
    return Response(200, "OK")

async def echo(req: Request) -> Response:
    return Response(200, "echo")

# ---- Main ----

def create_app() -> App:
    app = App()
    app.router.add("GET", "/health", health_check)
    app.router.add("POST", "/echo", echo)

    def auth_check(req: Request) -> Optional[Response]:
        if "authorization" not in req.headers:
            return Response(401, "Unauthorized")
        return None

    app.middleware.before(auth_check)
    return app
