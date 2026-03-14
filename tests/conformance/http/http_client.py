"""HTTP client functions — no errors expected."""
from mimir.http import get, post, put, delete, patch

r1 = get("https://api.example.com/data")
r2 = post("https://api.example.com/submit", json={"key": "value"})
r3 = put("https://api.example.com/update", json={"key": "new"})
r4 = delete("https://api.example.com/remove")
r5 = patch("https://api.example.com/partial", data=b"raw")
