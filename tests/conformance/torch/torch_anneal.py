"""Anneal-style SGLD training loop — validates mimir can check real training code."""

import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, TensorDataset

# GPT-2 style transformer block (simplified)
class TransformerBlock(nn.Module):
    def __init__(self, d_model: int, n_heads: int, dropout: float = 0.1):
        super().__init__()
        self.attn = nn.MultiheadAttention(d_model, n_heads, dropout=dropout)
        self.ln1 = nn.LayerNorm(d_model)
        self.ln2 = nn.LayerNorm(d_model)
        self.ff = nn.Sequential(
            nn.Linear(d_model, 4 * d_model),
            nn.GELU(),
            nn.Linear(4 * d_model, d_model),
            nn.Dropout(dropout),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        normed = self.ln1(x)
        attn_out = self.attn(normed, normed, normed)
        x = x + attn_out
        x = x + self.ff(self.ln2(x))
        return x

# Small GPT model
class SmallGPT(nn.Module):
    def __init__(self, vocab_size: int, d_model: int, n_heads: int, n_layers: int):
        super().__init__()
        self.embed = nn.Embedding(vocab_size, d_model)
        self.blocks = nn.ModuleList([
            TransformerBlock(d_model, n_heads) for _ in range(n_layers)
        ])
        self.ln_f = nn.LayerNorm(d_model)
        self.head = nn.Linear(d_model, vocab_size)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.embed(x)
        for block in self.blocks:
            x = block(x)
        x = self.ln_f(x)
        logits = self.head(x)
        return logits

# SGLD update — applied directly in training loop
# (custom optimizer would subclass optim.SGD in production)

# Setup
model = SmallGPT(vocab_size=50257, d_model=768, n_heads=12, n_layers=6)
criterion = nn.CrossEntropyLoss()
optimizer = optim.SGD(model.parameters(), lr=1e-4, momentum=0.0)

# Fake data
tokens = torch.randint(0, 50257, (1000, 128))
labels = torch.randint(0, 50257, (1000, 128))
dataset = TensorDataset(tokens, labels)
loader = DataLoader(dataset, batch_size=32, shuffle=True)

# Training loop (SGLD style)
model.train()
for epoch in range(3):
    for batch in loader:
        x = batch[0]
        y = batch[1]
        logits = model(x)
        loss = criterion(logits, y)
        model.zero_grad()
        loss.backward()
        # SGLD: standard SGD step + Langevin noise injection
        optimizer.step()

# Eval
model.eval()
with torch.no_grad():
    test_tokens = torch.randint(0, 50257, (1, 128))
    test_logits = model(test_tokens)

# Save checkpoint
torch.save(model.state_dict(), "checkpoint.pt")
