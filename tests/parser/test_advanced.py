"""Advanced Python features."""

# Walrus operator
if (n := len([1, 2, 3])) > 2:
    print(f"List has {n} elements")

# Starred assignment
first, *middle, last = range(10)

# Async/await
import asyncio

async def main():
    async for item in aiter():
        pass
    async with aopen("f") as f:
        pass
    result = await some_coroutine()
    yield result
    yield from other_gen()

# Complex f-strings
name = "world"
msg = f"Hello {name!r}, {2+2=}, {'nested' + ' string'}"

# Exception groups (Python 3.11+)
try:
    pass
except* ValueError as eg:
    pass
except* TypeError:
    pass

# Decorators
def decorator(func):
    return func

@decorator
@decorator
class MyClass:
    pass

# Comprehensions
gen = (x for x in range(10) if x % 2 == 0)
setcomp = {x * 2 for x in range(5)}
dictcomp = {k: v for k, v in zip("abc", [1, 2, 3]) if v > 1}

# Slicing
data = [1, 2, 3, 4, 5]
sub = data[1:4:2]
rev = data[::-1]

# Nonlocal
def outer():
    x = 1
    def inner():
        nonlocal x
        x += 1
    inner()
    return x

# Augmented assignment
x = 1
x += 1
x -= 1
x *= 2
x //= 3
x **= 2
x &= 0xFF
x |= 0x01
x ^= 0x10
x >>= 1
x <<= 2
x %= 5
x /= 2

# Star expressions
a = [*range(5), *[6, 7]]
b = {**{"a": 1}, **{"b": 2}}
