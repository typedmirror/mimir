"""Torch virtual module: nn.Module subclassing and forward pass."""

import torch
import torch.nn as nn

class SimpleModel(nn.Module):
    def __init__(self, in_dim: int, out_dim: int):
        super().__init__()
        self.linear = nn.Linear(in_dim, out_dim)
        self.relu = nn.ReLU()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.linear(x)
        x = self.relu(x)
        return x

# Construct and use
model = SimpleModel(10, 5)
inp = torch.randn(32, 10)
out = model(inp)

# Module methods
params = model.parameters()
model.train()
model.eval()
model.zero_grad()
sd = model.state_dict()

# Move model
model.to("cuda")
model.cuda()
model.cpu()

# Sequential
seq = nn.Sequential(
    nn.Linear(10, 20),
    nn.ReLU(),
    nn.Linear(20, 5),
)
seq_out = seq(inp)

# Loss
criterion = nn.CrossEntropyLoss()

# Containers
layers = nn.ModuleList([nn.Linear(10, 10) for _ in range(3)])
