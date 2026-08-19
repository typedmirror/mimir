"""Zoo (Tier 1): vector_add — elementwise vector addition.

Expression:  z = x + y

Tolerance: abs 1e-5. A single float32 add per element, no accumulation —
error is bounded by the rounding unit (~1.2e-7 relative), so 1e-5 absolute
holds with wide margin at the input magnitudes used here.

Runnable-leg convention (see zoo/README.md): deterministic inputs built
from mimir.array's zeros()/ones() — the only two creation functions
implemented identically in both the pure-Python shim (python/mimir/array.py)
and the checker's virtual module (src/checker/virtual_modules.odin). randn()
exists in the shim but is NOT exported by the checker's virtual module, so
it cannot be used inside a file that also has to `mimir check` clean; zeros/
ones keeps the same file checker-clean, shim-runnable, and compile-gpu-clean
end to end.
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def vector_add(x: Tensor[float32, 1024], y: Tensor[float32, 1024]) -> Tensor[float32, 1024]:
    return x + y


if __name__ == "__main__":
    x = ones(1024)
    y = ones(1024)
    z = vector_add(x, y)
    assert z.shape == (1024,)
    print("vector_add: ok, output shape", z.shape)
