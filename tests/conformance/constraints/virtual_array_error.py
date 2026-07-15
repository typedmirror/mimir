# Virtual module: Tensor_Type not assignable to int/str

from mimir.array import zeros

a = zeros((3, 4))
x: int = a  # E[T001]: Incompatible types
