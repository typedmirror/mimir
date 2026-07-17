"""Torch training: concatenate with squeeze/unsqueeze mismatch."""

import torch
import torch.nn as nn
import torch.optim as optim

# PLANTED: cat dimension mismatch with squeeze/unsqueeze — checker reports shape error when unsqueezed tensors have incompatible concat dims

class SequentialModule(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(32, 64)
        self.fc2 = nn.Linear(32, 48)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out1 = self.fc1(x)
        out2 = self.fc2(x)
        return out1, out2

model = SequentialModule()
optimizer = optim.Adam(model.parameters(), lr=0.001)
criterion = nn.MSELoss()

# Training data
batch_size = 16
x_batch = torch.randn(batch_size, 32)
y_batch = torch.randn(batch_size, 64)

# Forward pass produces two outputs with different shapes
out1, out2 = model(x_batch)  # (batch, 64), (batch, 48)

# Add dimensions
out1_unsqueezed = out1.unsqueeze(2)  # (batch, 64, 1)
out2_unsqueezed = out2.unsqueeze(2)  # (batch, 48, 1)

# PLANTED BUG: Concatenate along dim=1 but different shapes in dim=1 (64 vs 48)
concatenated = torch.cat([out1_unsqueezed, out2_unsqueezed], dim=1)  # E? dimension mismatch — 64 and 48 incompatible for cat on dim=1

loss = concatenated.sum()  # Simplified: just compute sum instead of loss
loss.backward()
optimizer.step()
