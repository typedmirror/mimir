"""Zoo (Tier 2): softmax — numerically-stable softmax, method form.

Expression:  y = x.softmax()   (= exp(x - max(x)) / sum(exp(x - max(x))),
                                  elementwise, shape-preserving)

N = 256 (single-workgroup bound — see zoo/README.md). Dispatch
requirement: exactly one 256-thread threadgroup — the emitted kernel does
an inline max-reduce into shared memory, a barrier, an exp+sum-reduce
into shared memory, a second barrier, then a per-thread divide
(D-G4v2(e) fixed the missing barrier between reading `sm[0]` (the max)
and the exp-overwrite that follows it — a real data race, not just a
correctness-of-value bug). Parity is corroboration of that fix, not proof
of race-freedom (the fixture asserting the barrier's presence both
directions is the proof — see D-G4v2(e) and the wave-1 contract note).

Tolerance: RELATIVE 3.05e-5, derived as N * eps_f32 with N=256 and
eps_f32 = 2^-23 ~= 1.1920929e-7 (two N-term reductions — the max-reduce
and the sum-of-exp-reduce — dominate; per-element exp/divide contribute a
handful of ULPs each, negligible next to the N-term accumulation).

Runnable-leg convention: input from ones() only, unannotated local.
x = ones(256) -> softmax of a uniform vector is uniform: each output
= 1/256 = 0.00390625 exactly representable relation (1/256 is a power of
two), so the expected constant has no rounding ambiguity of its own.
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def softmax(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.softmax()


if __name__ == "__main__":
    x = ones(256)
    y = softmax(x)
    assert y.shape == (256,)
    print("softmax: ok, output shape", y.shape)
