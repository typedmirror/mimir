"""D-G4v2 clause (c) positive fixture (L4/candor): 1D non-matmul param
broadcast. `a` is a length-1 scalar param broadcast against the length-N
`x`/`y` — the old emitter always indexed every param as `param[tid]`,
which read out of bounds for every tid > 0 on a length-1 buffer. Fixed:
len-N params index [tid], len-1 params index [0].
"""

from mimir.array import Tensor, gpu, float32

@gpu
def saxpy(
    a: Tensor[float32, 1],
    x: Tensor[float32, 1024],
    y: Tensor[float32, 1024],
) -> Tensor[float32, 1024]:
    return a * x + y
