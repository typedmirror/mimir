from typing import assert_type

# Alias of generic type
StringList = list[str]
sl: StringList = ["a", "b", "c"]
assert_type(sl, list[str])

# Alias of alias
MyInt = int
MyNum = MyInt
x: MyNum = 42
assert_type(x, int)

# Multiple levels
Ints = list[int]
Matrix = list[Ints]

# Wrong type through nested alias
bad: MyNum = "text"  # E
