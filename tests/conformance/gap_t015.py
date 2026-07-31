# Duplicate base class
class MyBase:
    pass

class Derived(MyBase, MyBase):  # E[T015]: duplicate base class MyBase
    pass
