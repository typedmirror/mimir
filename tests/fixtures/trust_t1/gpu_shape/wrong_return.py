"""GPU integration: genuine shaped-vs-shaped return mismatch must still fire.

Negative case for the D6 companion fix (shape-erasure on a failed matmul's
result + the symmetric is_assignable src.ndim==0 acceptance): proves neither
change made Tensor return-type checking universally permissive. x is a
concretely-shaped (3,3) tensor (never erased — no failed op produced it),
returned where (5,5) is declared. T003 must fire.
"""

from mimir.array import Tensor, gpu, float32

@gpu
def wrong_return(x: Tensor[float32, 3, 3]) -> Tensor[float32, 5, 5]:
    return x  # planted: T003, real shape mismatch (3,3) vs (5,5)
