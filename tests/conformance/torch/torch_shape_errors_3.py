"""Torch training: optimizer wrong keyword argument."""

import torch
import torch.nn as nn
import torch.optim as optim

# PLANTED: optimizer wrong kwarg — checker reports unexpected keyword argument 'learning_rate' for Adam (should be 'lr')

class RegressionModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(10, 64)
        self.relu1 = nn.ReLU()
        self.fc2 = nn.Linear(64, 32)
        self.relu2 = nn.ReLU()
        self.fc3 = nn.Linear(32, 1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.relu1(self.fc1(x))
        x = self.relu2(self.fc2(x))
        x = self.fc3(x)
        return x

# Setup
model = RegressionModel()
criterion = nn.MSELoss()

# PLANTED BUG: 'learning_rate' is not a valid kwarg for Adam, should be 'lr'
optimizer = optim.Adam(model.parameters(), learning_rate=0.001)  # E? wrong keyword argument 'learning_rate' instead of 'lr'

# Dummy data
x_train = torch.randn(100, 10)
y_train = torch.randn(100, 1)

# Training step
for epoch in range(5):
    output = model(x_train)
    loss = criterion(output, y_train)
    optimizer.zero_grad()
    loss.backward()
    optimizer.step()
