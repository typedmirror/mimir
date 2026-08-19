"""D-G3v2 negative fixture (L4/candor): a reduction over more elements than
the single-workgroup bound (256) must REFUSE loudly, not silently truncate.
Two-pass (multi-group) reduction is a named wave-2 item, not implemented
here — this fixture proves the refusal fires rather than emitting a
kernel that silently sums/maxes only the first 256 of 300 elements.
"""

from mimir.array import Tensor, gpu, float32

@gpu
def sum_over_bound(x: Tensor[float32, 300]) -> Tensor[float32, 1]:
    return x.sum()
