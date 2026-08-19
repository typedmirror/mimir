"""D-G4v2 clause (b) negative fixture (L4/candor): tensor subscript
expressions inside @gpu function bodies have no compute-graph
representation. The old extractor silently treated `x[0]` as `x` (a
passthrough) — GPU014 now refuses loudly instead.
"""

from mimir.array import Tensor, gpu, float32

@gpu
def bad_index(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    y = x[0]
    return y
