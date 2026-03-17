"""ML layers: type stubs for mimir.ml layers and activations"""
from typing import assert_type
from mimir.ml import Linear, Conv2d, LayerNorm, BatchNorm, Dropout, Embedding
from mimir.ml import relu, gelu, silu, sigmoid, tanh, softmax, log_softmax
from mimir.ml import Module, Tensor

# Tensor constructor returns a tensor
_x = Tensor([1.0, 2.0, 3.0])

# Activation functions accept and return tensors
_r = relu(_x)
_s = sigmoid(_x)
_t = tanh(_x)

# Softmax with dim
_sm = softmax(_x, dim=0)

# Layer constructors return layer instances
_layer = Linear(784, 256)

# Module constructor returns Module instance
_m = Module()

# Other layers construct successfully
_conv = Conv2d(3, 16, 3, stride=1, padding=1)
_ln = LayerNorm(256)
_bn = BatchNorm(64)
_drop = Dropout(0.5)
_emb = Embedding(1000, 128)

# Invalid attribute on layer
_layer.nonexistent_method  # E
