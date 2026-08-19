"""D-G4v2 clause (f) / N2 fixture (L4/candor): method-form activation calls
(x.relu(), x.exp(), ...) must extract to their REAL GPU_Op_Kind node in the
compute graph, not an empty/opaque node and not a silent passthrough of the
base tensor. Verified empirically (src/gpu/compute_graph.odin extract_call's
Attribute_Expr branch already covers these names correctly) — this fixture
+ the emitted-content assertions in gpu_emit_backend_test.py are the
permanent regression proof N2 asked for ("method-form activations are NOT
[proven]" going in; this makes them proven and keeps them proven).
"""

from mimir.array import Tensor, gpu, float32

@gpu
def relu_method(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.relu()

@gpu
def sigmoid_method(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.sigmoid()

@gpu
def tanh_method(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.tanh()

@gpu
def exp_method(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.exp()

@gpu
def log_method(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.log()

@gpu
def sqrt_method(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.sqrt()
