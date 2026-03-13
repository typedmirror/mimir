from typing import TypedDict

class Config(TypedDict):
    host: str
    port: int

# Good construction
c1: Config = Config(host="localhost", port=8080)

# Wrong field type
c2: Config = Config(host="localhost", port="bad")  # E
