import shelve

def open_cache():
    db = shelve.open('/tmp/data')
    return db
