"""Untyped JSON operations — mimir.json.load/loads return dict[str, Any]."""
from mimir.json import load, loads
from typing import assert_type

data = loads('{"key": "value"}')
assert_type(data, dict)

file_data = load("data.json")
assert_type(file_data, dict)
