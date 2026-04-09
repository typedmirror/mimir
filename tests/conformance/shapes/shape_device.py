"""Shape constraints: device tracking — CPU/GPU tensor placement."""

from mimir.array import zeros

# Create tensors on CPU (default)
a = zeros((3, 4))
b = zeros((4, 5))

# Same device operations are fine
c = a @ b  # OK: both on CPU

# Transfer to GPU
a_gpu = a.cuda()      # → CUDA device
b_gpu = b.cuda()      # → CUDA device

# Same device after transfer
d = a_gpu @ b_gpu     # OK: both on CUDA
