"""Test mimir.ml runtime: simple training loop"""
from mimir.ml import Linear, relu, cross_entropy, Adam, Tensor
import numpy as np

# Create a simple model
layer1 = Linear(4, 8)
layer2 = Linear(8, 3)

# Dummy data
x = Tensor(np.random.randn(16, 4))
targets = Tensor(np.array([0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0]))

# Optimizer
opt = Adam(layer1.parameters() + layer2.parameters(), lr=0.01)

# Training loop
for epoch in range(5):
    # Forward
    h = relu(layer1(x))
    pred = layer2(h)
    loss = cross_entropy(pred, targets)

    # Backward
    loss.backward()
    opt.step()
    opt.zero_grad()

    print(f"epoch {epoch}: loss={loss.item():.4f}")

print("Training complete!")
