"""Smoke test: Data processing pipeline with dataclass-like patterns.
Tests: class hierarchies, generic processors, type narrowing with isinstance,
decorator patterns, comprehension typing.
"""
from typing import TypeVar, Generic, List, Optional, Callable, Dict

T = TypeVar('T')
R = TypeVar('R')

# ---- Pipeline stages ----

class Stage(Generic[T, R]):
    def __init__(self, name: str, transform: Callable[[T], R]) -> None:
        self.name = name
        self.transform = transform

    def run(self, data: T) -> R:
        return self.transform(data)

class FilterStage(Generic[T]):
    def __init__(self, name: str, predicate: Callable[[T], bool]) -> None:
        self.name = name
        self.predicate = predicate

    def run(self, data: List[T]) -> List[T]:
        return [item for item in data if self.predicate(item)]

# ---- Record types ----

class Record:
    def __init__(self, id: int, value: float, label: str) -> None:
        self.id = id
        self.value = value
        self.label = label

    def is_valid(self) -> bool:
        return self.value >= 0 and len(self.label) > 0

class ProcessedRecord:
    def __init__(self, id: int, normalized: float, category: str) -> None:
        self.id = id
        self.normalized = normalized
        self.category = category

# ---- Pipeline ----

class Pipeline:
    def __init__(self) -> None:
        self.stages: List[str] = []
        self._stats: Dict[str, int] = {}

    def process(self, records: List[Record]) -> List[ProcessedRecord]:
        # Validate
        valid = [r for r in records if r.is_valid()]
        self._stats["valid"] = len(valid)
        self._stats["invalid"] = len(records) - len(valid)

        # Normalize
        if len(valid) == 0:
            return []

        values = [r.value for r in valid]
        mn = min(values)
        mx = max(values)
        rng = mx - mn if mx != mn else 1.0

        # Transform
        results: List[ProcessedRecord] = []
        for r in valid:
            norm = (r.value - mn) / rng
            cat = "high" if norm > 0.5 else "low"
            results.append(ProcessedRecord(
                id=r.id,
                normalized=norm,
                category=cat,
            ))

        self._stats["processed"] = len(results)
        return results

    def get_stats(self) -> Dict[str, int]:
        return self._stats

# ---- Utilities ----

def partition(
    items: List[Record],
    key: Callable[[Record], bool],
) -> tuple:
    yes: List[Record] = []
    no: List[Record] = []
    for item in items:
        if key(item):
            yes.append(item)
        else:
            no.append(item)
    return (yes, no)

# ---- Main ----

def main() -> None:
    records = [
        Record(1, 10.0, "alpha"),
        Record(2, 20.0, "beta"),
        Record(3, -5.0, ""),     # invalid
        Record(4, 30.0, "gamma"),
        Record(5, 15.0, "delta"),
    ]

    pipeline = Pipeline()
    results = pipeline.process(records)
    stats = pipeline.get_stats()

    high, low = partition(records, lambda r: r.value > 15.0)

if __name__ == "__main__":
    main()
