# Regression: GPU precision dtype Type_IDs (mimir.array's float32/int32/etc.) must
# stay stable across re-entrant virtual-registry init. register_mimir_array runs more
# than once against the same live registry per file under mimir check/LSP/conform's
# multi-file path (once from project setup, again inside checker's per-file resolution).
# Before the idempotency guard, the second call silently reassigned reg.gpu_float32_id
# etc. to a fresh Type_ID, so a function's own declared return dtype could fail to ==
# its own param dtype — a bare identity function would falsely mismatch itself.
# This file must check with ZERO errors.

from mimir.array import Tensor, gpu, float32, int32

@gpu
def identity_f32(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    return x

@gpu
def identity_i32(n: Tensor[int32, 8]) -> Tensor[int32, 8]:
    return n
