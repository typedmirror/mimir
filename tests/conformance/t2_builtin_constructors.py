# T2 regression: builtin container constructors propagate element types.
# list(xs) was Unknown, which the aug-assign loop then "refined" into garbage
# ('str | bytes | list[Any]') → T003 FP on `return output`.
from typing import List, assert_type


class Model:
    def __init__(self, n: int) -> None:
        self.bias: List[float] = [0.0] * n

    def forward(self, x: List[float]) -> List[float]:
        output = list(self.bias)
        for i in range(len(output)):
            for j in range(len(x)):
                output[i] += x[j]
        return output


def probes(xs: List[float]) -> None:
    assert_type(list(xs), List[float])
    assert_type(set(xs), set[float])
    assert_type(frozenset(xs), set[float])
    d = {"a": 1}
    assert_type(dict(d), dict[str, int])
    assert_type(list(d), List[str])


def misuse(xs: List[float]) -> List[str]:
    # list(list[float]) is list[float], not list[str] — real bug, must fire
    return list(xs)  # E
