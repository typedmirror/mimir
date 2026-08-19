"""Zoo (Tier 2): elementwise_math — .exp()/.log()/.sqrt()/.abs() chain.

Expression:  a = x.exp()
             b = a.log()
             c = b.sqrt()
             return c.abs()

(N1 — unlocked by L1 seam (5): method-form .exp()/.log()/.sqrt()/.abs()
now exist as precise same-shape/dtype Tensor->Tensor methods
(src/checker/array_check.odin), so this entry no longer needs the
Any-typed free-function imports the D-G1v2 canon bans.)

Tolerance: abs 1e-5. Four chained elementwise ops, no cross-element
accumulation; each libm call (exp/log/sqrt) is well-conditioned near the
O(1) magnitudes used here, so per-element error stays at a handful of
ULPs through the whole chain — well under 1e-5.

Runnable-leg convention (zoo/README.md / vector_add.py header): input
from ones() only, unannotated local. x = ones(256) -> exp(1) = e,
log(e) = 1, sqrt(1) = 1, abs(1) = 1 -> result = 1.0 everywhere (chosen
because it round-trips exactly through all four ops, giving an exact
expected constant).
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def elementwise_math(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    a = x.exp()
    b = a.log()
    c = b.sqrt()
    return c.abs()


if __name__ == "__main__":
    x = ones(256)
    y = elementwise_math(x)
    assert y.shape == (256,)
    print("elementwise_math: ok, output shape", y.shape)
