"""mimir runtime shim package.

Lets @gpu kernel files (`from mimir.array import Tensor, gpu, float32, ...`)
run directly under CPython for debugging, while the same source is also
statically checked and AOT-compiled to MSL/WGSL/SPIR-V/PTX by the mimir
Odin toolchain (`mimir_bin check`, `mimir_bin compile-gpu`). This package
has no relationship to the Odin binary at build/check time — mimir_bin
resolves `mimir.array` as a virtual module and never imports this code.
"""
