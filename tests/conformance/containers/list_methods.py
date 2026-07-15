from typing import assert_type

nums: list[int] = [1, 2, 3]

# Correct
assert_type(nums.pop(), int)
assert_type(nums.index(1), int)
assert_type(nums.count(1), int)
good1: list[int] = nums.copy()

# Errors
bad1: str = nums.pop()  # E[T001]
bad2: int = nums.append(4)  # E[T001]
bad3: str = nums.index(1)  # E[T001]
assert_type(nums.pop(), str)  # E[T006]
assert_type(nums.count(1), bool)  # E[T006]
bad4: int = nums.copy()  # E[T001]
