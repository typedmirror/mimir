from typing import assert_type

# Real-world config class pattern
class Config:
    def __init__(self, host: str, port: int) -> None:
        self.host = host
        self.port = port

class ServerConfig(Config):
    def __init__(self, host: str, port: int, ssl: bool) -> None:
        self.host = host
        self.port = port
        self.ssl = ssl

sc = ServerConfig("localhost", 8080, True)
assert_type(sc.host, str)
assert_type(sc.port, int)
assert_type(sc.ssl, bool)

# Parent still works
c = Config("localhost", 8080)
assert_type(c.host, str)

# Wrong arg count for child
ServerConfig("localhost", 8080)  # E
