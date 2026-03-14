"""Valid route definitions — no errors expected."""
from mimir.http import route, serve, Request, Response

@route("GET", "/")
def index(req: Request) -> Response:
    return Response.html("<h1>Hello</h1>")

@route("POST", "/api/data")
def create_data(req: Request) -> Response:
    data = req.json()
    return Response.json({"ok": True})

@route("GET", "/api/health")
def health(req: Request) -> Response:
    return Response.json({"status": "ok"})

serve(port=8080)
