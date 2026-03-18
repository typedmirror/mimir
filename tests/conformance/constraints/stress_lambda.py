# Stress: lambda constraint inference
# Known limitation: lambda caller→param doesn't fully propagate
# because lambda scopes may not be in func_args_map.

double = lambda x: x * 2
result = double(5)
