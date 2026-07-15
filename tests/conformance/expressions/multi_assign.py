# Expression results flow into annotated assignments
bad1: int = "hello" + "world"  # E[T001]
bad2: str = 1 + 2  # E[T001]
bad3: bool = 1.0 + 2.0  # E[T001]
