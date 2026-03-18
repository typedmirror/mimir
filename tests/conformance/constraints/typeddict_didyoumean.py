# §3.5: TypedDict "did you mean?" suggestion on invalid key access

settings = {}
settings["timeout"] = 30
settings["retries"] = 3
settings["verbose"] = True

x: str = settings["timeout"]  # E: Incompatible types
settings["timout"]  # E: Invalid TypedDict key
