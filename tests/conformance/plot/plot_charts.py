from typing import assert_type
from mimir.plot import plot, scatter, bar, hist, heatmap, pie, save, show, figure, subplots
from mimir.array import zeros

x = zeros((10,))
y = zeros((10,))

# Line chart returns Figure
fig = plot(x, y, title="Test")
fig.save("test.svg")

# Scatter
s = scatter(x, y, title="Scatter")
s.xlabel("X axis")

# Histogram
h = hist(x, bins=20, title="Distribution")

# Heatmap
data = zeros((5, 5))
hm = heatmap(data, cmap="viridis")

# Pie
p = pie([1.0, 2.0, 3.0], labels=["a", "b", "c"])

# Figure creation
f = figure(width=10, height=8)

# Subplots returns tuple
result = subplots(2, 2)
