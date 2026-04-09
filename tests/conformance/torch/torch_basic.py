"""Torch virtual module: basic tensor creation and operations."""

import torch

# Tensor creation — all should resolve without errors
x = torch.zeros(3, 4)
y = torch.ones(3, 4)
z = torch.randn(3, 4)
e = torch.empty(3, 4)
r = torch.rand(3, 4)
f = torch.full((3, 4), 1.0)

# From data
t = torch.tensor([1, 2, 3])
a = torch.arange(0, 10, 2)
l = torch.linspace(0.0, 1.0, 5)
i = torch.eye(3)

# Composition
c = torch.cat([x, y], dim=0)
s = torch.stack([x, y], dim=0)

# Math ops
m = torch.matmul(x, y.T)
mm = torch.mm(x, y.T)

# Reductions
total = torch.sum(x)
avg = torch.mean(x)
mx = torch.max(x)

# Comparison
eq = torch.eq(x, y)
close = torch.allclose(x, y)

# Context managers
with torch.no_grad():
    out = x + y

# Utility
torch.manual_seed(42)
check = torch.is_tensor(x)

# Device
dev = torch.device("cpu")

# Dtypes
dt = torch.float32
