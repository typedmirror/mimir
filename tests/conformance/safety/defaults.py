def append_to(item, target=[]):  # E[SAF009]
    target.append(item)
    return target

def with_dict(d={}):  # E[SAF009]
    pass

def with_set(s=set()):  # E[SAF009]
    pass

def ok_none(x=None):
    pass

def ok_tuple(t=(1, 2)):
    pass

def ok_int(n=0):
    pass
