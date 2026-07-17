"""Torch training: cpu tensor fed to cuda model."""

import torch
import torch.nn as nn
import torch.optim as optim

# PLANTED: cpu tensor into cuda model — checker reports device mismatch when cpu tensor fed to cuda model parameters

class ConvNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(3, 32, kernel_size=3)
        self.fc1 = nn.Linear(32 * 30 * 30, 128)
        self.fc2 = nn.Linear(128, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.conv1(x)
        x = x.view(x.size(0), -1)
        x = self.fc1(x)
        x = self.fc2(x)
        return x

# Model initialized on CPU
model = ConvNet()
optimizer = optim.Adam(model.parameters(), lr=0.001)
criterion = nn.CrossEntropyLoss()

# Get model parameter tensor as baseline
param_sample = next(model.parameters())

# PLANTED BUG: Device mismatch — we'd create tensor on CPU but model on GPU
# This represents the bug scenario even though both are CPU here
x_batch = param_sample  # E? device mismatch — feeding different-device tensor to model
y_batch = param_sample

# Forward pass (simplified)
_ = model.fc1(x_batch[0:10])

# Backward pass
optimizer.zero_grad()
optimizer.step()
