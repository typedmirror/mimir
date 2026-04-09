"""Shape constraints: realistic ML pipeline with multiple operations."""

from mimir.array import zeros

# === Full neural network training step ===

# Data: batch of 64 flattened MNIST images
X = zeros((64, 784))       # (batch, features)
y = zeros((64, 10))        # (batch, classes) one-hot labels

# Layer 1: 784 → 256
W1 = zeros((784, 256))
b1 = zeros((256,))

# Layer 2: 256 → 128
W2 = zeros((256, 128))
b2 = zeros((128,))

# Layer 3: 128 → 10
W3 = zeros((128, 10))
b3 = zeros((10,))

# Forward pass — shapes propagate through chain
h1 = X @ W1               # (64, 784) @ (784, 256) → (64, 256) ✓
h1 = h1 + b1              # (64, 256) + (256,) → broadcast ✓

h2 = h1 @ W2              # (64, 256) @ (256, 128) → (64, 128) ✓
h2 = h2 + b2              # (64, 128) + (128,) → broadcast ✓

logits = h2 @ W3           # (64, 128) @ (128, 10) → (64, 10) ✓
logits = logits + b3       # (64, 10) + (10,) → broadcast ✓

# Loss computation
diff = logits + y          # (64, 10) + (64, 10) → ✓

# === Shape error: mismatched layer dimensions ===
W_bad = zeros((512, 128))  # Wrong! h1 is (64, 256), not (64, 512)
bad = h1 @ W_bad           # E: inner dimensions 256 != 512

# === Transpose ===
Wt = W1.T                 # (784, 256).T → (256, 784)
grad = h1 @ Wt            # (64, 256) @ (256, 784) → (64, 784) ✓
