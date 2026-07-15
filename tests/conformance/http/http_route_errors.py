"""Route validation errors."""
from mimir.http import route, Request, Response

@route("POST", "/api/data")
def no_param() -> Response:  # E[HTTP001]: HTTP001
    return Response.json({})

@route("GET", "/api/users/{user_id}")
def get_user(req: Request) -> Response:  # E[HTTP004]: HTTP004
    return Response.json({})

@route("GET", "/")
def index(req: Request) -> Response:
    return Response.html("<h1>Hi</h1>")

@route("GET", "/")
def duplicate(req: Request) -> Response:  # E[HTTP003]: HTTP003
    return Response.html("dup")

@route("DELETE", "/api/items")
def delete_items(req: Request):  # E[HTTP002]: HTTP002
    pass
