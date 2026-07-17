from mimir.array import Tensor, gpu, float32, exp, log, sqrt

@gpu
def exp_log(x: Tensor[float32, 512]) -> Tensor[float32, 512]:
    return log(exp(x))

@gpu
def sqrt_pow(x: Tensor[float32, 256], y: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return sqrt(x) + pow(x, y)

@gpu
def clamp_abs(x: Tensor[float32, 128]) -> Tensor[float32, 128]:
    return abs(x)
