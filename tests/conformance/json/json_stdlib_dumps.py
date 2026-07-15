"""stdlib json.dumps serializability checking."""
import json

json.dumps({1, 2, 3})  # E[JSON001]: JSON001
json.dumps({"key": "value"})
json.dumps([1, 2, True, None, "hello"])
