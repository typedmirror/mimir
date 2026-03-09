# Container method signatures

# List methods
x: list[int] = [1, 2, 3]
x.append(4)
x.insert(0, 5)
x.remove(3)
x.clear()
x.reverse()
x.sort()
x.extend([6, 7])
val: int = x.pop()
idx: int = x.index(1)
cnt: int = x.count(2)
y: list[int] = x.copy()

# Dict methods
d: dict[str, int] = {"a": 1}
v: int = d.get("a")
v2: int = d.pop("b")
d.update({"c": 3})
d.clear()
d2: dict[str, int] = d.copy()

# Set methods
s: set[int] = {1, 2, 3}
s.add(4)
s.remove(2)
s.discard(5)
s.clear()
s2: set[int] = s.copy()

# String methods
name: str = "hello"
up: str = name.upper()
lo: str = name.lower()
parts: list[str] = name.split(",")
pos: int = name.find("l")
joined: str = ",".join(["a", "b"])
ok: bool = name.startswith("he")
stripped: str = name.strip()
replaced: str = name.replace("l", "r")

# Wrong arg type should error
x.append("bad")  # E
