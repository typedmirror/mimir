"""Torch training: concatenate dimension mismatch."""

import torch
import torch.nn as nn
import torch.optim as optim

# PLANTED: cat dim mismatch — checker reports dimension mismatch when concatenating tensors with incompatible shapes

class MultiHeadNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.branch1 = nn.Linear(64, 32)
        self.branch2 = nn.Linear(64, 16)
        self.combine = nn.Linear(48, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out1 = self.branch1(x)
        out2 = self.branch2(x)
        combined = torch.cat([out1, out2], dim=1)
        return self.combine(combined)

model = MultiHeadNet()
optimizer = optim.Adam(model.parameters(), lr=0.001)
criterion = nn.CrossEntropyLoss()

# Training data
batch_size = 16
x_batch = torch.randn(batch_size, 64)
y_batch = torch.randint(0, 10, (batch_size,))

# Create tensors with mismatched shapes
tensor_a = torch.randn(batch_size, 20, 10)
tensor_b = torch.randn(batch_size, 15, 10)  # Different middle dimension

# PLANTED BUG: Concatenate along dim=1 but tensor_b has different shape in that dim
concatenated = torch.cat([tensor_a, tensor_b], dim=1)  # E? dimension mismatch in concatenation along dim=1

logits = model(x_batch)
loss = criterion(logits, y_batch)
loss.backward()
optimizer.step()
