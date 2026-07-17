"""GPU restrictions: each GPU001-010 fires correctly"""

from mimir.array import Tensor, gpu, float32

@gpu
def bad_string_param(x: str) -> str:  # E[GPU001]
    return x

@gpu
def bad_string_literal(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    name = "hello"  # E[GPU001]
    return x

@gpu
def bad_fstring(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    msg = f"value: {x}"  # E[GPU002]
    return x

@gpu
def bad_str_call(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    s = str(x)  # E[GPU002]
    return x

@gpu
def bad_list(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    items = [1, 2, 3]  # E[GPU003]
    return x

@gpu
def bad_dict(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    d = {"a": 1}  # E[GPU003]
    return x

@gpu
def bad_comprehension(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    items = [i for i in range(10)]  # E[GPU003]
    return x

@gpu
def bad_exception(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    try:  # E[GPU004]
        return x
    except:
        return x

@gpu
def bad_raise(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    raise ValueError("bad")  # E[GPU004]
    return x  # E[F001]: unreachable after raise

@gpu
def bad_recursion(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    return bad_recursion(x)  # E[GPU005]

@gpu
def bad_getattr(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    v = getattr(x, "shape")  # E[GPU006]
    return x

@gpu
def bad_while_true(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    while True:  # E[GPU008]
        x = x + x
    return x

@gpu
def bad_global(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    global y  # E[GPU010]
    return x

@gpu
def bad_yield(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    yield x  # E[GPU010]
    return x

@gpu
def bad_nested_def(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    def helper():  # E[GPU010]
        pass
    return x
