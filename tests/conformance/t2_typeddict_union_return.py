# T2 regression: dict literals returned where the annotation is a
# Union/Optional of TypedDicts must NOT produce T003 (the FP class).
# TypedDict-ness comes from the is_typeddict flag, not a name-suffix heuristic
# (Ok/Err deliberately do NOT end in "Dict").
from typing import TypedDict, Union, Optional


class Ok(TypedDict):
    id: int
    name: str


class Err(TypedDict):
    error: str
    code: int


def get(flag: bool) -> Optional[Ok]:
    if flag:
        return None
    return {"id": 1, "name": "a"}


def handler(flag: bool) -> Union[Ok, Err]:
    if flag:
        return {"error": "no", "code": 404}
    u = get(True)
    if u is None:
        return {"error": "missing", "code": 404}
    return u


def wrong_keys() -> Union[Ok, Err]:
    # non-string keys can never satisfy a TypedDict — real bug, must fire
    return {1: "x"}  # E[T003]
