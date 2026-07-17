"""Torch training: reshape element-count mismatch."""

import torch
import torch.nn as nn
import torch.optim as optim

# PLANTED: reshape/view element-count mismatch — checker reports shape mismatch when reshaping 100 elements to (5,25) which requires 125 elements

class AutoEncoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.encoder = nn.Linear(100, 50)
        self.relu = nn.ReLU()
        self.decoder = nn.Linear(50, 100)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.relu(self.encoder(x))
        x = self.decoder(x)
        return x

model = AutoEncoder()
optimizer = optim.SGD(model.parameters(), lr=0.01)
criterion = nn.MSELoss()

# Training data: 32 samples of 100-dim features
batch_size = 32
x_batch = torch.randn(batch_size, 100)

# Forward pass
encoded = model(x_batch)

# Get one sample from batch for reshape demo
sample = encoded[0]  # Get first sample (100 elements)

# PLANTED BUG: Try to reshape 100-element tensor to (5, 25) which needs 125 elements
# This is an element-count mismatch
reshaped = sample.reshape(5, 25)  # E? element-count mismatch — 100 elements cannot reshape to (5,25)=125

loss = criterion(reshaped.view(batch_size, -1), x_batch)
loss.backward()
optimizer.step()
