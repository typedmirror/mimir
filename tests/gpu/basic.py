"""GPU basic: @gpu detection and valid functions"""

@gpu
def valid_add(x: Tensor[float32, 32], y: Tensor[float32, 32]) -> Tensor[float32, 32]:
    return x + y

@gpu
def valid_matmul(a: Tensor[float32, 4, 3], b: Tensor[float32, 3, 5]) -> Tensor[float32, 4, 5]:
    return a @ b

@gpu
def valid_scalar_ops(x: Tensor[float32, 16]) -> Tensor[float32, 16]:
    y = x + x
    z = y * x
    return z - y

@gpu
def valid_activation(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    return relu(x)

@gpu
def valid_ternary(x: Tensor[float32, 32], y: Tensor[float32, 32]) -> Tensor[float32, 32]:
    return x if True else y

def not_gpu_function(x):
    """This is NOT a @gpu function and should be ignored"""
    return str(x)
