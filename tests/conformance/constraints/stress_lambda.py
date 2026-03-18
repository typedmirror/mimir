# Stress: lambda constraint inference
# Lambda caller→param requires func_args_map + sym_to_scope + backfill
# All three subsystems now handle lambdas, but full propagation
# through the convergence loop needs additional work.

double = lambda x: x * 2
result = double(5)
