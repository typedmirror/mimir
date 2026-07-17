"""Torch training: Linear layer dimension mismatch variant."""

import torch
import torch.nn as nn
import torch.optim as optim

# PLANTED: Linear out→in dim mismatch variant — checker reports shape error when embedding output feeds to mismatched linear layer

class EmbeddingClassifier(nn.Module):
    def __init__(self, vocab_size: int, embedding_dim: int):
        super().__init__()
        self.embedding = nn.Embedding(vocab_size, embedding_dim)
        # Bug: fc1 expects 128, but embedding_dim is 64
        self.fc1 = nn.Linear(128, 64)
        self.fc2 = nn.Linear(64, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.embedding(x)  # (batch, seq_len) -> (batch, seq_len, embedding_dim)
        x = x.view(x.size(0), -1)  # Flatten to (batch, seq_len*embedding_dim=embedding_dim) - approximate
        x = self.fc1(x)        # E? expects 128 input but receives 64
        x = self.fc2(x)
        return x

# Setup
vocab_size = 1000
embedding_dim = 64
model = EmbeddingClassifier(vocab_size, embedding_dim)
optimizer = optim.Adam(model.parameters(), lr=0.001)
criterion = nn.CrossEntropyLoss()

# Training data: sequences of token indices
batch_size = 32
seq_len = 50
x_batch = torch.randint(0, vocab_size, (batch_size, seq_len))
y_batch = torch.randint(0, 10, (batch_size,))

# Forward pass
logits = model(x_batch)
loss = criterion(logits, y_batch)

loss.backward()
optimizer.step()
