"""GPU015 negative fixture (L4/candor, post-freeze structural fix): an
unrecognized tensor method call inside a @gpu function body has no
GPU_Op_Kind mapping. The old behavior silently extracted to nothing — no
computation, no result write, exit 0 — which is exactly how the missing
`.abs()` case (see method_form_activations.py) went undetected until
scale's on-device parity run caught the resulting device-vs-shim mismatch.
GPU015 refuses loudly instead, closing the whole class of bug (not just
the one missing case).
"""

from mimir.array import Tensor, gpu, float32

@gpu
def unknown_method(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.frobnicate()
