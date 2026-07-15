"""PERF008: stale cache — db mutation without cache invalidation"""
_cache = {}

class _DB:
    def fetch(self, id): pass
    def update(self, id, data): pass

db = _DB()

def get_item(id):
    if id in _cache:
        return _cache[id]
    item = db.fetch(id)
    _cache[id] = item  # E[PERF006]

def update_item(id, data):
    db.update(id, data)  # E[PERF008]

def update_with_clear(id, data):
    db.update(id, data)
    _cache[id] = data  # E[PERF006]
