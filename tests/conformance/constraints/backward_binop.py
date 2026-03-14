# Phase II: BinOp constraint — x + 1 → x is numeric

def double(x):
    return x + x

# x supports + with itself → numeric type
# double(3) should work without error
result = double(3)
