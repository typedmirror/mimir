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

# API004: type mismatch — spec says "id" is integer but handler returns string
@route("GET", "/users/{id}")
def get_user_bad_type(req: Request, id: str) -> Response:  # E: duplicate route
    return Response(body={"id": "not_an_int", "name": "bob"})  # API004 is Warning
