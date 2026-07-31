# PERF010: list() wrapping a list comprehension is redundant

data = [1, 2, 3, 4, 5]

# Trigger PERF010: list() wrapping a list comprehension
result = list([x * 2 for x in data])  # E[PERF010]: list() wrapping a comprehension is redundant

# This is fine (no wrapper):
direct = [x * 2 for x in data]

# This should also trigger PERF010 with set():
result2 = set({x * 2 for x in data})  # E[PERF010]: set() wrapping a comprehension is redundant
