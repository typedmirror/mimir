class Database:
    """Another example with dict."""
    cache = {}  # E[SAF011]: mutable class variable

    def get_item(self, key):
        return self.cache.get(key)
