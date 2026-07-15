"""SAF010: use after close — resource access after with block"""

with open("data.txt") as f:
    _data = f.read()

f.read()  # E[SAF003|SAF010]
