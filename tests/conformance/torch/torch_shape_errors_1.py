"""Torch training: Linear layer input dimension mismatch."""

import torch
import torch.nn as nn
import torch.optim as optim

# PLANTED: Linear out→in dim mismatch — checker reports shape mismatch when fc1 outputs 256 but fc2 expects 300

class SimpleNet(nn.Module):
    def __init__(self):
        super().__init__()
        # Layer 1: 784 (MNIST input) -> 256 (hidden)
        self.fc1 = nn.Linear(784, 256)
        # Layer 2: expects 300 input, but fc1 outputs 256 — mismatch
        self.fc2 = nn.Linear(300, 128)  # E? shape mismatch — fc1 outputs 256, not 300
        self.fc3 = nn.Linear(128, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.fc1(x)      # (batch, 784) -> (batch, 256)
        x = self.fc2(x)      # ERROR: expects (batch, 300) but receives (batch, 256)
        x = self.fc3(x)      # (batch, 128) -> (batch, 10)
        return x

# Setup model and optimizer
model = SimpleNet()
optimizer = optim.SGD(model.parameters(), lr=0.01)
criterion = nn.CrossEntropyLoss()

# Typical training batch (MNIST-like)
batch_size = 32
x_batch = torch.randn(batch_size, 784)
y_batch = torch.randint(0, 10, (batch_size,))

# Forward pass would fail with shape mismatch
logits = model(x_batch)
loss = criterion(logits, y_batch)

# Backward pass
loss.backward()
optimizer.step()
