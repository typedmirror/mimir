from pkg import helper

a: str = helper(42)    # OK — helper returns str
b: int = helper(42)    # E  — str not assignable to int
