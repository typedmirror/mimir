"""Typed JSON parsing via mimir.json.parse — returns schema type."""
from mimir.json import parse, read
from typing import TypedDict, assert_type

class Config(TypedDict):
    host: str
    port: int
    debug: bool

config = parse('{"host": "localhost"}', Config)
assert_type(config["host"], str)
assert_type(config["port"], int)
assert_type(config["debug"], bool)

# read also supports typed parsing
loaded = read("config.json", Config)
assert_type(loaded["host"], str)
