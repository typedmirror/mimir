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

    passed = sum(1 for _, ok in _results if ok)
    total = len(_results)
    print(f"\nshim_functional_test: {passed}/{total} checks passed")
    if passed != total:
        sys.exit(1)


if __name__ == '__main__':
    main()
