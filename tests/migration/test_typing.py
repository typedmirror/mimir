"""Test migration detection for typing patterns."""
from typing import Union, Optional, List, Dict, Tuple, Set, FrozenSet, Type

# MIG001: Union syntax
def process(x: Union[str, int]) -> Union[bool, None]:
    pass

# MIG002: Optional syntax
def maybe(x: Optional[str]) -> Optional[int]:
    pass

# MIG003: Builtin generics
def container(items: List[int], mapping: Dict[str, int]) -> Tuple[str, ...]:
    s: Set[int] = set()
    fs: FrozenSet[str] = frozenset()
    return ("ok",)

# MIG004: typing.Type
def check_type(cls: Type[int]) -> None:
    pass

# Nested: Union inside List (should detect both)
def nested(x: List[Union[str, int]]) -> None:
    pass
