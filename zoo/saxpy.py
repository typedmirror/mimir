"""Zoo (Tier 2): saxpy — scalar-times-vector-plus-vector, 1D param broadcast.

Expression:  z = a * x + y     (a is Tensor[float32, 1], broadcast scalar)

(D-G4v2(c) — 1D param broadcast: a length-1 param classifies as a scalar
broadcast, indexed `[0]` at every thread, vs. x/y's length-256 `[tid]`
per-element index; any other length would refuse loudly by design.)

Tolerance: abs 1e-5. One scalar-broadcast multiply + one elementwise add
per element, no accumulation across elements — a couple of ULPs, far
under 1e-5.

Runnable-leg convention (zoo/README.md / vector_add.py header): inputs
from ones() only, unannotated locals. a = ones(1) + ones(1) = [2.0]
(elementwise add of two Tensor[float32,1], not a raw Python scalar — a
stays a Tensor so the checker types it against the Tensor[float32,1]
param exactly as declared). x = ones(256), y = ones(256) ->
z = 2*1 + 1 = 3.0 everywhere.
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def saxpy(
    a: Tensor[float32, 1],
    x: Tensor[float32, 256],
    y: Tensor[float32, 256],
) -> Tensor[float32, 256]:
    return a * x + y


if __name__ == "__main__":
    a = ones(1) + ones(1)
    x = ones(256)
    y = ones(256)
    z = saxpy(a, x, y)
    assert z.shape == (256,)
    print("saxpy: ok, output shape", z.shape)
