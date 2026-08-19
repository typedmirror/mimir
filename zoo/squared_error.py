"""Zoo (Tier 1): squared_error — elementwise squared error, NO reduction.

(Renamed from an earlier mse_loss draft — a mean reduction is a Tier-2
concern gated on D-G3v2's size-general reducer fix; this entry stays
elementwise so it is green today.)

Expression:  e = (pred - target) * (pred - target)

Tolerance: abs 1e-5. Two elementwise float32 ops per output element (one
sub, one mul), no accumulation across elements — error is bounded by a
couple of rounding units, so 1e-5 absolute holds with wide margin.

Runnable-leg convention (see zoo/README.md / vector_add.py header):
deterministic inputs from zeros()/ones() only. pred=ones(512),
target=zeros(512) -> diff=1 everywhere -> e=1 everywhere.
"""

from mimir.array import Tensor, gpu, float32, ones, zeros


@gpu
def squared_error(
    pred: Tensor[float32, 512],
    target: Tensor[float32, 512],
) -> Tensor[float32, 512]:
    diff = pred - target
    return diff * diff


if __name__ == "__main__":
    pred = ones(512)
    target = zeros(512)
    e = squared_error(pred, target)
    assert e.shape == (512,)
    print("squared_error: ok, output shape", e.shape)
