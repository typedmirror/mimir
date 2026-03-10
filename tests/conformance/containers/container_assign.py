# Container type assignability edge cases
nums: list[int] = [1, 2, 3]

bad1: list[str] = nums  # E
bad2: dict[int, str] = {"a": 1}  # E
bad3: set[str] = {1, 2}  # E
bad4: tuple[str, int] = (1, "hello")  # E
