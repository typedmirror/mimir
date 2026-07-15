"""Torch virtual module: error detection tests."""

import torch
import torch.nn as nn
import torch.optim as optim

# Wrong arg count to Linear
layer = nn.Linear(10)  # E[T004]: Missing required argument

# Attribute that doesn't exist on Module
model = nn.Module()
model.nonexistent_method()  # E[T007]: Undefined attribute

# Wrong arg count to optimizer
opt = optim.Adam()  # E[T004]: Missing required argument
