# Lambda constraint inference: caller→param propagates through convergence loop

double = lambda x: x * 2
result: str = double(5)  # E[T001]: Incompatible types
