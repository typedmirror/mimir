# For loop iterator typing
nums: list[int] = [1, 2, 3]
total: int = 0
for n in nums:
    total = total + n

names: list[str] = ["a", "b"]
for name in names:
    x: int = name  # E[T001]
