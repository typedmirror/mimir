"""JSON schema and serialization errors — JSON001, JSON002."""
from mimir.json import parse, serialize

serialize({1, 2, 3})  # E: JSON001

parse("{}", int)  # E: JSON002
