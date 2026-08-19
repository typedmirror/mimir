#!/usr/bin/env python3
"""
Functional correctness test for python/mimir/array.py — the pure-Python
runtime shim that lets @gpu kernel files run directly under CPython.

This is NOT an import-clean check (the dual-execution proof already covers
that: tests/gpu/*.py import without exception under plain CPython). It is a
check that the ARITHMETIC is right: this script loads the real kernel
functions from tests/gpu/{shape_integration,math_ops,training_step}.py,
calls them directly with seeded (deterministic) tensors built from the
shim's own randn(), and compares every output against an INDEPENDENT
reference implementation written from scratch in this file — plain
nested-loop Python, no code shared with the shim's Tensor class. A test
that only re-derived the shim's own matmul to check the shim's matmul would
be circular; this doesn't do that.

Replaces an earlier ad-hoc "ALL FUNCTIONAL CHECKS PASSED" capture that lived
in a scratch script and got purged along with everything else in /tmp —
that capture is no longer reproducible by anyone. This is its tracked
replacement.

Grown for Phase G Wave 1 / L1 "gate" (docs/FACTORY_CONTRACT_G.md seam 3):
covers the new method-form surface added to python/mimir/array.py —
__truediv__/__rtruediv__, method reductions (.sum/.mean/.max/.min, each
Tensor[T,1] per the checker's new typing), method activations
(.relu/.sigmoid/.tanh/.softmax), and method math (.exp/.log/.sqrt/.abs) —
each checked against an INDEPENDENT reference (never the shim's own math).

Usage:
    PYTHONPATH=python python3 tests/scripts/shim_functional_test.py
"""

import importlib.util
import math
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO_ROOT, 'python'))

from mimir.array import Tensor, ones, randn  # noqa: E402 - sys.path must be set first


def _load_kernel_module(relpath):
    """Load a tests/gpu/*.py fixture as a module, running its @gpu functions
    for real (the decorator is an identity no-op under this shim)."""
    path = os.path.join(REPO_ROOT, relpath)
    name = os.path.splitext(os.path.basename(path))[0] + '_kernelmod'
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# -----------------------------------------------------------------------
# Independent reference math — deliberately NOT calling into Tensor's own
# __matmul__/__add__/etc, so a bug shared between "kernel" and "checker"
# can't hide from this test the way it could if this just re-ran the shim.
# -----------------------------------------------------------------------

def ref_matmul(a, a_shape, b, b_shape):
    m, k = a_shape
    k2, n = b_shape
    assert k == k2, f"inner dim mismatch {a_shape} @ {b_shape}"
    out = [0.0] * (m * n)
    for i in range(m):
        for j in range(n):
            s = 0.0
            for p in range(k):
                s += a[i * k + p] * b[p * n + j]
            out[i * n + j] = s
    return out


def ref_broadcast_add_row(mat, mat_shape, row):
    m, n = mat_shape
    assert len(row) == n
    return [mat[i * n + j] + row[j] for i in range(m) for j in range(n)]


def close(a, b, tol=1e-6):
    if len(a) != len(b):
        return False
    return all(abs(x - y) <= tol * max(1.0, abs(y)) for x, y in zip(a, b))


def ref_sum(flat):
    total = 0.0
    for v in flat:
        total += v
    return total


def ref_mean(flat):
    return ref_sum(flat) / len(flat)


def ref_max(flat):
    m = flat[0]
    for v in flat[1:]:
        if v > m:
            m = v
    return m


def ref_min(flat):
    m = flat[0]
    for v in flat[1:]:
        if v < m:
            m = v
    return m


def ref_relu(flat):
    return [v if v > 0.0 else 0.0 for v in flat]


def ref_sigmoid(flat):
    return [1.0 / (1.0 + math.exp(-v)) for v in flat]


def ref_tanh(flat):
    return [(math.exp(v) - math.exp(-v)) / (math.exp(v) + math.exp(-v)) for v in flat]


def ref_softmax(flat):
    m = ref_max(flat)
    exps = [math.exp(v - m) for v in flat]
    s = ref_sum(exps)
    return [e / s for e in exps]


def ref_truediv(a, b):
    return [av / bv for av, bv in zip(a, b)]


_results = []


def check(name, condition, detail=""):
    _results.append((name, condition))
    status = 'PASS' if condition else 'FAIL'
    suffix = f" — {detail}" if detail and not condition else ""
    print(f"{status}  {name}{suffix}")


def main():
    # -- hand-computable spot check: ones(2,3) @ ones(3,4) -> every element 3.0
    # No independent-reference code needed to verify this one — a reader can
    # do the arithmetic in their head: each output cell sums 3 terms of 1*1.
    spot = ones(2, 3) @ ones(3, 4)
    check("Tensor.__matmul__: ones(2,3) @ ones(3,4) shape (2, 4)",
          spot.shape == (2, 4), f"got {spot.shape}")
    check("Tensor.__matmul__: ones(2,3) @ ones(3,4) == 3.0 everywhere",
          all(v == 3.0 for v in spot.data), f"got {spot.data}")

    # -- linear_forward: (32,784)@(784,128) + broadcast(128,) -> (32,128) --
    shape_mod = _load_kernel_module('tests/gpu/shape_integration.py')
    x = randn(32, 784, seed=1)
    w = randn(784, 128, seed=2)
    b = randn(128, seed=3)
    out = shape_mod.linear_forward(x, w, b)
    check("linear_forward: output shape (32, 128)", out.shape == (32, 128), f"got {out.shape}")
    expected_h = ref_matmul(x.data, x.shape, w.data, w.shape)
    expected = ref_broadcast_add_row(expected_h, (32, 128), b.data)
    check("linear_forward: matches independent matmul+broadcast-add reference",
          close(out.data, expected))

    # -- math_ops: exp/log roundtrip, sqrt+pow, abs --
    math_mod = _load_kernel_module('tests/gpu/math_ops.py')

    xv = randn(512, seed=4)
    rt = math_mod.exp_log(xv)
    check("exp_log: output shape (512,)", rt.shape == (512,), f"got {rt.shape}")
    check("exp_log: log(exp(x)) round-trips to x within 1e-6", close(rt.data, xv.data, tol=1e-6))

    # sqrt_pow computes sqrt(x) + x**y; keep x non-negative (sqrt's domain)
    # by reusing the same non-negative x for both terms, matching what the
    # kernel signature actually requires of its caller.
    sx = Tensor.from_flat([abs(v) for v in randn(256, seed=5).data], (256,))
    sy = randn(256, seed=6)
    sp = math_mod.sqrt_pow(sx, sy)
    expected_sp = [math.sqrt(a) + a ** yv for a, yv in zip(sx.data, sy.data)]
    check("sqrt_pow: output shape (256,)", sp.shape == (256,), f"got {sp.shape}")
    check("sqrt_pow: matches independent sqrt(x)+x**y reference",
          close(sp.data, expected_sp))

    cx = randn(128, seed=7)
    ca = math_mod.clamp_abs(cx)
    expected_abs = [abs(v) for v in cx.data]
    check("clamp_abs: output shape (128,)", ca.shape == (128,), f"got {ca.shape}")
    check("clamp_abs: matches abs() reference", close(ca.data, expected_abs))

    # -- train_step: matmul -> elementwise square -> matmul -> MSE chain --
    train_mod = _load_kernel_module('tests/gpu/training_step.py')
    tx = randn(32, 784, seed=8)
    w1 = randn(784, 256, seed=9)
    w2 = randn(256, 10, seed=10)
    labels = randn(32, 10, seed=11)
    loss = train_mod.train_step(tx, w1, w2, labels)
    check("train_step: output shape (32, 10)", loss.shape == (32, 10), f"got {loss.shape}")

    h = ref_matmul(tx.data, tx.shape, w1.data, w1.shape)
    h = [v * v for v in h]
    logits = ref_matmul(h, (32, 256), w2.data, w2.shape)
    diff = [lv - yv for lv, yv in zip(logits, labels.data)]
    expected_loss = [d * d for d in diff]
    check("train_step: matches independent forward+MSE reference",
          close(loss.data, expected_loss))

    # -- reduction.py: method-form reductions (sum/mean/max/min), each Tensor[T,1]
    reduction_mod = _load_kernel_module('tests/gpu/reduction.py')

    rs = randn(1024, seed=12)
    out_sum = reduction_mod.sum_reduce(rs)
    check("sum_reduce: output shape (1,)", out_sum.shape == (1,), f"got {out_sum.shape}")
    check("sum_reduce: matches independent sum reference",
          close(out_sum.data, [ref_sum(rs.data)]))

    rm = randn(256, seed=13)
    out_mean = reduction_mod.mean_reduce(rm)
    check("mean_reduce: output shape (1,)", out_mean.shape == (1,), f"got {out_mean.shape}")
    check("mean_reduce: matches independent mean reference",
          close(out_mean.data, [ref_mean(rm.data)]))

    rmax = randn(512, seed=14)
    out_max = reduction_mod.max_reduce(rmax)
    check("max_reduce: output shape (1,)", out_max.shape == (1,), f"got {out_max.shape}")
    check("max_reduce: matches independent max reference",
          close(out_max.data, [ref_max(rmax.data)]))

    rmin = randn(512, seed=15)
    out_min = reduction_mod.min_reduce(rmin)
    check("min_reduce: output shape (1,)", out_min.shape == (1,), f"got {out_min.shape}")
    check("min_reduce: matches independent min reference",
          close(out_min.data, [ref_min(rmin.data)]))

    # -- softmax.py: method-form activation, two sizes --
    softmax_mod = _load_kernel_module('tests/gpu/softmax.py')

    sm1 = randn(256, seed=16)
    out_sm1 = softmax_mod.softmax_1d(sm1)
    check("softmax_1d: output shape (256,)", out_sm1.shape == (256,), f"got {out_sm1.shape}")
    check("softmax_1d: matches independent softmax reference",
          close(out_sm1.data, ref_softmax(sm1.data)))
    check("softmax_1d: sums to 1.0", abs(sum(out_sm1.data) - 1.0) <= 1e-6)

    sm2 = randn(128, seed=17)
    out_sm2 = softmax_mod.softmax_method(sm2)
    check("softmax_method: output shape (128,)", out_sm2.shape == (128,), f"got {out_sm2.shape}")
    check("softmax_method: matches independent softmax reference",
          close(out_sm2.data, ref_softmax(sm2.data)))

    # -- method-form activations directly on Tensor (relu/sigmoid/tanh —
    # not yet exercised by any @gpu fixture, so spot-checked here) --
    av = randn(64, seed=18)
    out_relu = av.relu()
    check("Tensor.relu: matches independent relu reference",
          close(out_relu.data, ref_relu(av.data)))

    out_sig = av.sigmoid()
    check("Tensor.sigmoid: matches independent sigmoid reference",
          close(out_sig.data, ref_sigmoid(av.data)))

    out_tanh = av.tanh()
    check("Tensor.tanh: matches independent tanh reference",
          close(out_tanh.data, ref_tanh(av.data)))

    # -- method-form elementwise math (mirrors the free-function forms
    # already covered above by exp_log/sqrt_pow/clamp_abs, but as methods) --
    mv = randn(64, seed=19)
    check("Tensor.exp: matches independent math.exp reference",
          close(mv.exp().data, [math.exp(v) for v in mv.data]))

    pv = Tensor.from_flat([abs(v) + 0.1 for v in randn(64, seed=20).data], (64,))
    check("Tensor.log: matches independent math.log reference",
          close(pv.log().data, [math.log(v) for v in pv.data]))
    check("Tensor.sqrt: matches independent math.sqrt reference",
          close(pv.sqrt().data, [math.sqrt(v) for v in pv.data]))

    nv = randn(64, seed=21)
    check("Tensor.abs: matches independent abs reference",
          close(nv.abs().data, [v if v >= 0 else -v for v in nv.data]))

    # -- __truediv__ / __rtruediv__ (Tensor/Tensor and scalar/Tensor) --
    dv_a = randn(64, seed=22)
    dv_b = Tensor.from_flat([abs(v) + 0.1 for v in randn(64, seed=23).data], (64,))
    out_div = dv_a / dv_b
    check("Tensor.__truediv__: matches independent elementwise division reference",
          close(out_div.data, ref_truediv(dv_a.data, dv_b.data)))

    out_rdiv = 2.0 / dv_b
    check("Tensor.__rtruediv__: matches independent elementwise division reference",
          close(out_rdiv.data, ref_truediv([2.0] * len(dv_b.data), dv_b.data)))

    passed = sum(1 for _, ok in _results if ok)
    total = len(_results)
    print(f"\nshim_functional_test: {passed}/{total} checks passed")
    if passed != total:
        sys.exit(1)


if __name__ == '__main__':
    main()
