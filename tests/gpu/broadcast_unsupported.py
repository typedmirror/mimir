"""D-G4v2 clause (c) negative fixture (L4/candor): a param shape that is
neither the kernel's full dispatch length nor a length-1 scalar has no
statically-correct 1D index and must REFUSE loudly (mirrors the S114 2D
broadcast fix's Unsupported branch) rather than silently emitting
`param[tid]`, which would read garbage/OOB for a length-4 buffer against
a 1024-wide dispatch.
"""

from mimir.array import Tensor, gpu, float32

@gpu
def bad_bcast(a: Tensor[float32, 4], x: Tensor[float32, 1024]) -> Tensor[float32, 1024]:
    return a * x
