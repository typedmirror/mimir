# Operator type checking test — arithmetic, string, comparison
# Expected: T005 for incompatible operator types

# Valid operations
a = 1 + 2          # int + int = int
b = 1.0 + 2        # float + int = float
c = "a" + "b"      # str + str = str
d = "a" * 3        # str * int = str
e = 1 / 2          # int / int = float (true division)
f = 7 // 2         # int // int = int
g = 7 % 3          # int % int = int
h = 2 ** 10        # int ** int = int

# Comparison always bool
i = 1 < 2
j = "a" == "b"

# Invalid: str + int → T005
bad = "a" + 1
