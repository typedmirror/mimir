# Subscript/indexing
nums: list[int] = [1, 2, 3]
x: int = nums[0]
d: dict[str, int] = {"a": 1}
y: int = d["a"]
s: str = "hello"
c: str = s[0]
t: tuple[int, str, bool] = (1, "a", True)
# Errors
bad: str = nums[0]  # E
bad2: int = s[0]    # E
