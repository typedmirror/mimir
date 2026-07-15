# Lambda expression typing
f = lambda x: x + 1
g = lambda: 42
# Lambda return type is inferred from body
bad: str = (lambda: 42)()  # E[T001]
