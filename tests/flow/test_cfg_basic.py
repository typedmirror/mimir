# Basic CFG test — straight-line, if/else, while, for
# Expected: 0 F001, 0 guards

x = 1
y = 2
z = x + y

if x > 0:
    a = 1
else:
    a = 2

# While loop
i = 0
while i < 10:
    i += 1

# For loop
total = 0
for item in [1, 2, 3]:
    total += item

# For-else
for val in []:
    pass
else:
    default = True

# Nested if
if x > 0:
    if y > 0:
        both_positive = True
    else:
        mixed = True
else:
    both_negative = True

# If-elif-else
if x == 1:
    label = "one"
elif x == 2:
    label = "two"
else:
    label = "other"
