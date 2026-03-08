# list[T] type inference and checking conformance

# Annotated lists — no errors
nums: list[int] = [1, 2, 3]
names: list[str] = ["alice", "bob"]

# Assignment mismatches
bad1: list[int] = ["a", "b"]   # E: list[str] not assignable to list[int]
bad2: list[str] = [1, 2, 3]    # E: list[int] not assignable to list[str]
