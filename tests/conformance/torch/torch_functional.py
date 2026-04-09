"""Torch virtual module: nn.functional usage."""

import torch
import torch.nn.functional as F

x = torch.randn(32, 10)
w = torch.randn(5, 10)

# Activations
a = F.relu(x)
b = F.gelu(x)
c = F.sigmoid(x)
d = F.softmax(x, dim=1)
e = F.leaky_relu(x)
f = F.silu(x)

# Loss functions
target = torch.randn(32, 10)
loss1 = F.mse_loss(x, target)
loss2 = F.l1_loss(x, target)

# Linear
out = F.linear(x, w)

# Dropout
dropped = F.dropout(x, p=0.5, training=True)

# Normalize
normed = F.normalize(x, p=2.0, dim=1)
