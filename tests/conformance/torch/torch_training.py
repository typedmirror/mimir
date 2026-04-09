"""Torch virtual module: full training loop."""

import torch
import torch.nn as nn
import torch.optim as optim

# Define model
class MLP(nn.Module):
    def __init__(self, input_size: int, hidden_size: int, output_size: int):
        super().__init__()
        self.fc1 = nn.Linear(input_size, hidden_size)
        self.fc2 = nn.Linear(hidden_size, output_size)
        self.relu = nn.ReLU()
        self.dropout = nn.Dropout(0.5)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.fc1(x)
        x = self.relu(x)
        x = self.dropout(x)
        x = self.fc2(x)
        return x

# Setup
model = MLP(784, 256, 10)
criterion = nn.CrossEntropyLoss()
optimizer = optim.Adam(model.parameters(), lr=0.001)

# Training step
x_batch = torch.randn(64, 784)
y_batch = torch.randint(0, 10, (64,))  # E? randint not registered

# Forward
logits = model(x_batch)
loss = criterion(logits, y_batch)

# Backward
optimizer.zero_grad()
loss.backward()
optimizer.step()

# Eval mode
model.eval()
with torch.no_grad():
    test_out = model(x_batch)

# Save/load
torch.save(model.state_dict(), "model.pt")

# LR scheduling
scheduler = optim.lr_scheduler.StepLR(optimizer, step_size=10)
scheduler.step()
