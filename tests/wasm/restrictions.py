# WASM restriction validation tests — WASM001-WASM008

@wasm
def valid_func(a: int, b: int) -> int:  # OK — fully typed
    return a + b

@wasm
def untyped_param(a, b):  # E: WASM001 — untyped parameter
    return a + b

@wasm
def string_ops(n: int) -> int:  # E: WASM002 — string operation
    s = "hello"
    return n

@wasm
def heap_alloc(n: int) -> int:  # E: WASM003 — heap allocation
    xs = [1, 2, 3]
    return n

@wasm
def exception_use(n: int) -> int:  # E: WASM004 — exception handling
    try:
        return n
    except:
        return 0

@wasm
def recursive_func(n: int) -> int:  # E: WASM005 — recursive call (warning)
    if n <= 1:
        return 1
    return n * recursive_func(n - 1)

@wasm
def dynamic_dispatch(n: int) -> int:  # E: WASM006 — dynamic dispatch
    return getattr(n, "real")

@wasm
def unsupported(n: int) -> int:  # E: WASM007 — unsupported construct
    global x
    return n

@wasm
def unbounded_loop(n: int) -> int:  # E: WASM008 — unbounded while loop
    while True:
        n = n + 1
    return n
