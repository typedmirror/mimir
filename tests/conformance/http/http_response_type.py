"""Response type methods — no errors expected."""
from mimir.http import Response
from typing import assert_type

r1 = Response.json({"key": "value"})
r2 = Response.html("<h1>Hello</h1>")
r3 = Response.text("plain text")
r4 = Response.redirect("/other")
