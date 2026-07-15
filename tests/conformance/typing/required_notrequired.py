# Required/NotRequired typing special forms for TypedDict

from typing import TypedDict, Required, NotRequired

class Config(TypedDict, total=False):
    host: Required[str]
    port: Required[int]
    debug: NotRequired[bool]

ok = Config(host="localhost", port=8080)
bad = Config(host="localhost")  # E[T004]: Missing required TypedDict field
