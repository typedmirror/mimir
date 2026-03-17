"""ML training: optimizer, loss, backward, grad"""
from typing import assert_type
from mimir.ml import Linear, Adam, SGD, AdamW
from mimir.ml import cross_entropy, mse_loss, binary_cross_entropy
from mimir.ml import Tensor, relu

# Tensor constructor returns tensor
_x = Tensor([1.0, 2.0])

# Activation returns tensor — relu(tensor) should resolve
_r = relu(_x)

# Loss functions return tensors
_pred = Tensor([0.1, 0.9])
_target = Tensor([0, 1])
_loss = cross_entropy(_pred, _target)

# Tensor autograd attributes
assert_type(_pred.requires_grad, bool)

# backward returns None
_pred.backward()

# detach returns tensor
_d = _pred.detach()

# Optimizer construction and methods
_layer = Linear(10, 5)
_opt = Adam(_layer.parameters(), lr=0.001)
_opt.step()
_opt.zero_grad()

_sgd = SGD(_layer.parameters(), lr=0.01, momentum=0.9)
_sgd.step()
_sgd.zero_grad()

_adamw = AdamW(_layer.parameters(), lr=0.001, weight_decay=0.01)

# Invalid optimizer attribute
_opt.nonexistent  # E
