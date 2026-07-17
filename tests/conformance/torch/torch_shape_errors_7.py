"""Torch training: view element-count mismatch variant."""

import torch
import torch.nn as nn
import torch.optim as optim

# PLANTED: reshape/view element-count mismatch variant — checker reports shape error when view() tries impossible shape

class FeatureExtractor(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc = nn.Linear(100, 128)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.fc(x)
        return x

model = FeatureExtractor()
optimizer = optim.SGD(model.parameters(), lr=0.01)

# Get a weight tensor from the model
weight_tensor = next(model.parameters())  # Shape: (128, 100)

# Forward pass produces 128-dim output
features = model.fc(weight_tensor[0:10])  # (10, 128)

# PLANTED BUG: Try to view 128 elements as (64, 64) which needs 4096 elements
# This is an impossible view operation
sample = features[0]  # Get one sample (128 elements)
impossible_view = sample.view(64, 64)  # E? element-count impossible — 128 cannot view as (64,64)=4096

loss = impossible_view.sum()
loss.backward()
optimizer.step()
