# WASM optimization pass tests — constant folding, dead code, peephole

@wasm
def constant_fold_add() -> int:
    # Should fold: 10 + 20 → 30
    return 10 + 20

@wasm
def constant_fold_mul() -> int:
    # Should fold: 5 * 6 → 30
    return 5 * 6

@wasm
def constant_fold_nested() -> int:
    # Should fold: (3 + 4) * 2 → 14
    return (3 + 4) * 2

@wasm
def dead_code_after_return(x: int) -> int:
    return x
    y: int = x + 1  # Dead code — should be eliminated
    return y

@wasm
def peephole_set_get(x: int) -> int:
    # local.set + local.get → local.tee
    y: int = x + 1
    return y
