"""D-G3v2 size-general reduction fixture (L4/candor, seam 2 — L4's own,
never tests/gpu/reduction.py or softmax.py, which are L1's).

Every kernel here is <= the single-workgroup bound (GPU_REDUCTION_BLOCK_BOUND
= 256, src/gpu/emit.odin) and includes at least one non-256 size per op, per
D-G3v2 ("parity must include >= 1 non-256 size per reduction the day they
land"). Each is expected to emit cleanly on msl/wgsl (tail-guarded single-
group reduction, real-N mean divisor, single write to result[0]) and to
REFUSE on ptx/spirv (D-G4v2 clause a — those backends have no cross-thread
reduction primitive).
"""

from mimir.array import Tensor, gpu, float32

@gpu
def sum_n100(x: Tensor[float32, 100]) -> Tensor[float32, 1]:
    return x.sum()

@gpu
def mean_n200(x: Tensor[float32, 200]) -> Tensor[float32, 1]:
    return x.mean()

@gpu
def max_n256(x: Tensor[float32, 256]) -> Tensor[float32, 1]:
    return x.max()

@gpu
def min_n64(x: Tensor[float32, 64]) -> Tensor[float32, 1]:
    return x.min()

@gpu
def softmax_n100(x: Tensor[float32, 100]) -> Tensor[float32, 100]:
    return x.softmax()
