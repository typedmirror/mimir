# /// script
# dependencies = ["requests"]
# requires-python = ">=3.10"
# ///

import requests

resp = requests.get("https://httpbin.org/get")
print(f"Status: {resp.status_code}")
