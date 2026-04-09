# TypeAlias with PEP 604 value-level unions

from typing import TypeAlias

# PEP 604: int | str in value context creates a union type
IntOrStr: TypeAlias = int | str

# Alias usage works
x: IntOrStr = 42
y: IntOrStr = "hello"

# Direct PEP 604 usage without TypeAlias
z: int | str = 3.14  # E: Incompatible types
