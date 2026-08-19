"""Pure-Python runtime shim for mimir's @gpu tensor surface.

Lets @gpu-decorated kernel files execute under plain CPython for debugging,
while the SAME source file also statically checks and AOT-compiles via the
mimir Odin toolchain (`mimir_bin check` / `mimir_bin compile-gpu`). Zero
dependencies (no numpy) — nested-list backed tensors, good enough for
correctness checks on small shapes, not for performance.

Canonical import surface: `from mimir.array import Tensor, gpu, float32, ...`
"""

import math
import random as _random


# ---------------------------------------------------------------------------
# dtypes — simple named sentinels, enough to satisfy Tensor[dtype, *dims]
# ---------------------------------------------------------------------------

class DType:
    __slots__ = ("name",)

    def __init__(self, name):
        self.name = name

    def __repr__(self):
        return self.name

    def __eq__(self, other):
        return isinstance(other, DType) and self.name == other.name

    def __hash__(self):
        return hash(self.name)


float32 = DType("float32")
float16 = DType("float16")
bfloat16 = DType("bfloat16")
int32 = DType("int32")
int64 = DType("int64")


# ---------------------------------------------------------------------------
# gpu decorator — identity under CPython (the compiled path is mimir_bin)
# ---------------------------------------------------------------------------

def gpu(fn):
    """Marks a kernel for AOT compilation by mimir_bin. Under plain CPython
    this is a no-op identity decorator so the same function runs directly."""
    return fn


# ---------------------------------------------------------------------------
# shape helpers — flat row-major storage + numpy-style broadcasting
# ---------------------------------------------------------------------------

def _infer_shape(nested):
    shape = []
    node = nested
    while isinstance(node, (list, tuple)):
        shape.append(len(node))
        node = node[0] if len(node) > 0 else None
    return tuple(shape)


def _flatten(nested, out):
    if isinstance(nested, (list, tuple)):
        for item in nested:
            _flatten(item, out)
    else:
        out.append(nested)
    return out


def _to_nested(flat, shape):
    if len(shape) == 0:
        return flat[0]
    if len(shape) == 1:
        return list(flat)
    stride = 1
    for d in shape[1:]:
        stride *= d
    return [_to_nested(flat[i * stride:(i + 1) * stride], shape[1:]) for i in range(shape[0])]


def _broadcast_shapes(a, b):
    la, lb = list(a), list(b)
    n = max(len(la), len(lb))
    la = [1] * (n - len(la)) + la
    lb = [1] * (n - len(lb)) + lb
    out = []
    for da, db in zip(la, lb):
        if da == db or da == 1 or db == 1:
            out.append(max(da, db))
        else:
            raise ValueError(f"shape mismatch, cannot broadcast {a} with {b}")
    return tuple(out)


def _strides_for(shape):
    strides = [1] * len(shape)
    acc = 1
    for i in range(len(shape) - 1, -1, -1):
        strides[i] = acc
        acc *= shape[i]
    return strides


def _broadcast_index(out_idx, out_shape, src_shape):
    """Map a multi-index in out_shape to a flat offset in a src_shape-shaped
    flat buffer, honoring numpy-style right-aligned broadcasting."""
    pad = len(out_shape) - len(src_shape)
    src_idx = out_idx[pad:]
    offset = 0
    strides = _strides_for(src_shape)
    for i, (idx, dim) in enumerate(zip(src_idx, src_shape)):
        offset += (idx if dim != 1 else 0) * strides[i]
    return offset


def _each_index(shape):
    if len(shape) == 0:
        yield ()
        return
    ranges = [range(d) for d in shape]

    def rec(prefix, rest):
        if not rest:
            yield tuple(prefix)
            return
        for i in rest[0]:
            yield from rec(prefix + [i], rest[1:])

    yield from rec([], ranges)


def _elementwise(a, b, op):
    a = a if isinstance(a, Tensor) else Tensor(a)
    if isinstance(b, Tensor):
        out_shape = _broadcast_shapes(a.shape, b.shape)
        b_flat, b_shape = b.data, b.shape
    else:
        out_shape = a.shape
        b_flat, b_shape = [b], ()
    a_flat, a_shape = a.data, a.shape

    out = [0.0] * (_numel(out_shape) if out_shape else 1)
    for out_idx in _each_index(out_shape):
        ai = _broadcast_index(out_idx, out_shape, a_shape) if a_shape else 0
        bi = _broadcast_index(out_idx, out_shape, b_shape) if b_shape else 0
        flat_pos = 0
        strides = _strides_for(out_shape)
        for k, ix in enumerate(out_idx):
            flat_pos += ix * strides[k]
        out[flat_pos] = op(a_flat[ai], b_flat[bi])
    return Tensor.from_flat(out, out_shape)


def _numel(shape):
    n = 1
    for d in shape:
        n *= d
    return n


def _unary(a, fn):
    a = a if isinstance(a, Tensor) else Tensor(a)
    return Tensor.from_flat([fn(v) for v in a.data], a.shape)


# ---------------------------------------------------------------------------
# Tensor
# ---------------------------------------------------------------------------

class Tensor:
    """Nested-list-backed tensor. Stores data flat (row-major) + shape."""

    __slots__ = ("data", "shape")

    def __init__(self, nested):
        if isinstance(nested, Tensor):
            self.data = list(nested.data)
            self.shape = nested.shape
        else:
            self.shape = _infer_shape(nested)
            self.data = _flatten(nested, [])

    @classmethod
    def from_flat(cls, flat, shape):
        t = cls.__new__(cls)
        t.data = list(flat)
        t.shape = tuple(shape)
        return t

    # Subscript typing: Tensor[float32, 32, 784] must work at *runtime* as
    # a type annotation. Returns the class itself (per shim contract) so
    # annotation evaluation at function-definition time never raises.
    def __class_getitem__(cls, params):
        return cls

    def tolist(self):
        return _to_nested(self.data, self.shape)

    def __repr__(self):
        return f"Tensor(shape={self.shape}, data={self.tolist()!r})"

    def __eq__(self, other):
        if not isinstance(other, Tensor):
            return NotImplemented
        return self.shape == other.shape and self.data == other.data

    # elementwise + broadcasting
    def __add__(self, other):
        return _elementwise(self, other, lambda x, y: x + y)

    def __radd__(self, other):
        return _elementwise(other, self, lambda x, y: x + y)

    def __sub__(self, other):
        return _elementwise(self, other, lambda x, y: x - y)

    def __rsub__(self, other):
        return _elementwise(other, self, lambda x, y: x - y)

    def __mul__(self, other):
        return _elementwise(self, other, lambda x, y: x * y)

    def __rmul__(self, other):
        return _elementwise(other, self, lambda x, y: x * y)

    def __pow__(self, other):
        return _elementwise(self, other, lambda x, y: x ** y)

    def __truediv__(self, other):
        return _elementwise(self, other, lambda x, y: x / y)

    def __rtruediv__(self, other):
        return _elementwise(other, self, lambda x, y: x / y)

    def __neg__(self):
        return Tensor.from_flat([-v for v in self.data], self.shape)

    def __abs__(self):
        return Tensor.from_flat([abs(v) for v in self.data], self.shape)

    # matmul: 2D @ 2D -> 2D (the case used by the kernel corpus).
    def __matmul__(self, other):
        if not isinstance(other, Tensor):
            other = Tensor(other)
        if len(self.shape) != 2 or len(other.shape) != 2:
            raise ValueError("matmul: only 2D @ 2D tensors are supported by this shim")
        m, k = self.shape
        k2, n = other.shape
        if k != k2:
            raise ValueError(f"matmul: inner dims mismatch {self.shape} @ {other.shape}")
        out = [0.0] * (m * n)
        a, b = self.data, other.data
        for i in range(m):
            for p in range(k):
                aip = a[i * k + p]
                if aip == 0:
                    continue
                row_off = p * n
                out_off = i * n
                for j in range(n):
                    out[out_off + j] += aip * b[row_off + j]
        return Tensor.from_flat(out, (m, n))

    def reshape(self, *shape):
        if len(shape) == 1 and isinstance(shape[0], (list, tuple)):
            shape = tuple(shape[0])
        if _numel(shape) != _numel(self.shape):
            raise ValueError(f"cannot reshape {self.shape} into {shape}")
        return Tensor.from_flat(self.data, shape)

    def flatten(self):
        return Tensor.from_flat(self.data, (len(self.data),))

    # -----------------------------------------------------------------
    # Method-form reductions — match the checker's Tensor[T,1] typing
    # (src/checker/array_check.odin): a rank-1, single-element result,
    # not a bare Python scalar, so shim output shape mirrors the
    # emitted device buffer ABI (single write to result[0]).
    # -----------------------------------------------------------------
    def sum(self):
        return Tensor.from_flat([sum(self.data)], (1,))

    def mean(self):
        return Tensor.from_flat([sum(self.data) / len(self.data)], (1,))

    def max(self):
        return Tensor.from_flat([max(self.data)], (1,))

    def min(self):
        return Tensor.from_flat([min(self.data)], (1,))

    # -----------------------------------------------------------------
    # Method-form activations (D-G1v2 canon: method forms only, no
    # free-function activation imports). Elementwise, shape-preserving.
    # -----------------------------------------------------------------
    def relu(self):
        return Tensor.from_flat([v if v > 0.0 else 0.0 for v in self.data], self.shape)

    def sigmoid(self):
        return Tensor.from_flat([1.0 / (1.0 + math.exp(-v)) for v in self.data], self.shape)

    def tanh(self):
        return Tensor.from_flat([math.tanh(v) for v in self.data], self.shape)

    def softmax(self):
        # Numerically stable: subtract the max before exponentiating.
        m = max(self.data)
        exps = [math.exp(v - m) for v in self.data]
        s = sum(exps)
        return Tensor.from_flat([e / s for e in exps], self.shape)

    # -----------------------------------------------------------------
    # Method-form elementwise math (N1 — mirrors the free functions
    # below, as methods; unlocks Tier-2 elementwise_math zoo entries).
    # -----------------------------------------------------------------
    def exp(self):
        return _unary(self, math.exp)

    def log(self):
        return _unary(self, math.log)

    def sqrt(self):
        return _unary(self, math.sqrt)

    def abs(self):
        return self.__abs__()


# ---------------------------------------------------------------------------
# constructors
# ---------------------------------------------------------------------------

def zeros(*shape):
    if len(shape) == 1 and isinstance(shape[0], (list, tuple)):
        shape = tuple(shape[0])
    return Tensor.from_flat([0.0] * _numel(shape), shape)


def ones(*shape):
    if len(shape) == 1 and isinstance(shape[0], (list, tuple)):
        shape = tuple(shape[0])
    return Tensor.from_flat([1.0] * _numel(shape), shape)


def randn(*shape, seed=0):
    if len(shape) == 1 and isinstance(shape[0], (list, tuple)):
        shape = tuple(shape[0])
    rng = _random.Random(seed)
    n = _numel(shape)
    return Tensor.from_flat([rng.gauss(0.0, 1.0) for _ in range(n)], shape)


# ---------------------------------------------------------------------------
# elementwise math functions used by kernel bodies
# ---------------------------------------------------------------------------

def exp(x):
    return _unary(x, math.exp)


def log(x):
    return _unary(x, math.log)


def sqrt(x):
    return _unary(x, math.sqrt)


def abs(x):  # noqa: A001 - intentional shadow, imported explicitly by kernels
    if isinstance(x, Tensor):
        return x.__abs__()
    import builtins
    return builtins.abs(x)


def pow(x, y):  # noqa: A001 - intentional shadow, imported explicitly by kernels
    if isinstance(x, Tensor) or isinstance(y, Tensor):
        return _elementwise(x, y, lambda a, b: a ** b)
    import builtins
    return builtins.pow(x, y)
