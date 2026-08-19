"""JSON schema and serialization errors — JSON001, JSON002, JSON003."""
from mimir.json import parse, serialize
from typing import TypedDict

serialize({1, 2, 3})  # E: JSON001

parse("{}", int)  # E: JSON002

# JSON003: TypedDict schema field type is not JSON-serializable (set has no
# canonical JSON representation — json_check.odin's is_json_serializable
# rejects Set_Type outright).
class BadSchema(TypedDict):
    tags: set[str]

parse("{}", BadSchema)  # E[JSON003]: TypedDict field type not JSON serializable
