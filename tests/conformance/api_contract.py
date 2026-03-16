from mimir.http import route, Request, Response

@route("POST", "/users")
def create_user(req: Request) -> Response:  # API001  # E
    return Response(body={"id": 1, "name": "alice", "username": "alice123"})

@route("GET", "/users/{id}")
def get_user(req: Request, id: str) -> Response:
    return Response(body={"id": 1})  # API002 is Warning, not caught by marker

@route("GET", "/health")
def health(req: Request) -> Response:
    return Response(body={"status": "ok"})  # API003 is Warning, not caught by marker
