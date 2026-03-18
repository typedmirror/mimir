# §3.5: Local dict → TypedDict inference from key assignments

config = {}
config["host"] = "localhost"
config["port"] = 8080
config["debug"] = True

# Inferred: TypedDict{host: str, port: int, debug: bool}
print(config["prot"])  # E: Invalid TypedDict key
