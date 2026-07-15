"""PERF006: unbounded cache — module-level dict growing without eviction"""
_cache = {}

def process(request_id, data):
    _cache[request_id] = data  # E[PERF006]
