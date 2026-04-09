"""Shape constraints: cross-device tensor operation detection."""

from mimir.array import zeros

# CPU tensor (default)
a = zeros((3, 4))

# GPU tensor (via .cuda())
b = zeros((4, 5)).cuda()

# Cross-device matmul — should error
c = a @ b  # E: cross-device
