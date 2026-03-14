"""Request type attribute access — no errors expected."""
from mimir.http import Request, Response, route
from typing import assert_type

@route("POST", "/test")
def handler(req: Request) -> Response:
    assert_type(req.method, str)
    assert_type(req.path, str)
    assert_type(req.query_string, str)
    assert_type(req.data, bytes)
    data = req.json()
    assert_type(data, dict)
    text = req.text()
    assert_type(text, str)
    return Response.json({"ok": True})
