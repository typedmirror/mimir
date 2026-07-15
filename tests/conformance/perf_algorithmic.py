"""Performance analysis: algorithmic anti-patterns.

PERF001 — string concatenation in loop
PERF002 — unnecessary list comprehension passed to consumer

These are .Performance severity diagnostics, not .Error.
No required markers — this file verifies no false positive .Error diagnostics.
Actual PERF rule detection is verified via 'mimir perf'.
"""

# --- PERF001: string concat in loop ---

# Detection: += on string-initialized variable in for loop
result = ""
items = [1, 2, 3]
for item in items:
    result += str(item)  # E[PERF001]

# Detection: += on string-initialized variable in while loop
msg = ""
i = 0
while i < 10:
    msg += "x"  # E[PERF001]
    i += 1

# Safe: int += in loop (not string)
count = 0
for item in items:
    count += 1

# Safe: string += outside loop
s = ""
s += "one"

# Safe: reinitialized each iteration (init inside loop body)
for item in items:
    x = ""
    x += str(item)


# --- PERF002: list comp passed to consumer function ---

data = [1, -2, 3, -4, 5]

# Detection: sum([...])
total = sum([x * x for x in data])  # E[PERF002]

# Detection: any([...])
has_neg = any([x < 0 for x in data])  # E[PERF002]

# Detection: sorted([...])
ordered = sorted([x for x in data])  # E[PERF002]

# Detection: "".join([...])
text = ",".join([str(x) for x in data])  # E[PERF002]

# Safe: generator expression (already optimal)
total2 = sum(x * x for x in data)

# Safe: list comp not passed to consumer
my_list = [x * x for x in data]
