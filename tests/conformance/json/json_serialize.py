"""JSON serialization — valid types should pass."""
from mimir.json import serialize, dumps
from typing import assert_type

# All these should be fine
result1 = serialize({"key": "value"})
assert_type(result1, str)

result2 = dumps([1, 2, 3])
assert_type(result2, str)

result3 = serialize({"nested": [1, True, None, "hello"]})
assert_type(result3, str)
