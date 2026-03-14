"""Path parameter validation — no errors expected."""
from mimir.http import route, Request, Response

@route("GET", "/users/{user_id}")
def get_user(req: Request, user_id: str) -> Response:
    return Response.json({"id": user_id})

@route("GET", "/posts/<post_id>/comments/<comment_id>")
def get_comment(req: Request, post_id: str, comment_id: str) -> Response:
    return Response.json({"post": post_id, "comment": comment_id})
