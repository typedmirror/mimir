# T2 regression: dataclasses field(default_factory=...) must NOT produce T001
# (the FP class), while real default/factory mismatches ARE still caught.
from dataclasses import dataclass, field
from typing import List


def make_strs() -> List[str]:
    return ["a"]


@dataclass
class Clean:
    tags: list[str] = field(default_factory=list)
    scores: dict[str, int] = field(default_factory=dict)
    names: List[str] = field(default_factory=make_strs)
    flag: bool = field(default=True)
    hidden: int = field(init=False, default=0)


@dataclass
class Buggy:
    # default value type mismatches the annotation — real bug, must fire
    label: str = field(default=5)  # E
    # factory returns list[str], annotation says int — real bug, must fire
    count: int = field(default_factory=make_strs)  # E
