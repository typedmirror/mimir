"""Smoke test: Feature engineering pipeline.
Tests: numeric operations, type annotations, generic containers,
comprehension typing, nested function scoping.
"""
from typing import List, Dict, Tuple, Optional, Callable
import math

# ---- Feature extractors ----

def normalize(values: List[float]) -> List[float]:
    """Min-max normalization to [0, 1]."""
    if len(values) == 0:
        return []
    mn = min(values)
    mx = max(values)
    rng = mx - mn
    if rng == 0:
        return [0.0] * len(values)
    return [(v - mn) / rng for v in values]

def standardize(values: List[float]) -> List[float]:
    """Z-score standardization."""
    n = len(values)
    if n == 0:
        return []
    mean = sum(values) / n
    variance = sum((v - mean) ** 2 for v in values) / n
    std = math.sqrt(variance) if variance > 0 else 1.0
    return [(v - mean) / std for v in values]

def one_hot_encode(categories: List[str]) -> Dict[str, List[int]]:
    """One-hot encode categorical values."""
    unique = sorted(set(categories))
    result: Dict[str, List[int]] = {}
    for cat in unique:
        result[cat] = [1 if c == cat else 0 for c in categories]
    return result

def bin_values(values: List[float], n_bins: int = 5) -> List[int]:
    """Bin continuous values into discrete buckets."""
    if len(values) == 0:
        return []
    mn = min(values)
    mx = max(values)
    if mn == mx:
        return [0] * len(values)
    bin_width = (mx - mn) / n_bins
    return [min(int((v - mn) / bin_width), n_bins - 1) for v in values]

# ---- Pipeline builder ----

class FeaturePipeline:
    def __init__(self) -> None:
        self.steps: List[Tuple[str, Callable[[List[float]], List[float]]]] = []

    def add_step(self, name: str, transform: Callable[[List[float]], List[float]]) -> "FeaturePipeline":
        self.steps.append((name, transform))
        return self

    def run(self, data: List[float]) -> List[float]:
        result = data
        for name, transform in self.steps:
            result = transform(result)
        return result

# ---- Cross-validation ----

def k_fold_split(
    data: List[List[float]],
    labels: List[int],
    k: int = 5,
) -> List[Tuple[List[List[float]], List[int], List[List[float]], List[int]]]:
    """Split data into k folds for cross-validation."""
    fold_size = len(data) // k
    folds: List[Tuple[List[List[float]], List[int], List[List[float]], List[int]]] = []

    for i in range(k):
        start = i * fold_size
        end = start + fold_size

        test_data = data[start:end]
        test_labels = labels[start:end]
        train_data = data[:start] + data[end:]
        train_labels = labels[:start] + labels[end:]

        folds.append((train_data, train_labels, test_data, test_labels))

    return folds

# ---- Main ----

def main() -> None:
    raw_ages = [25.0, 30.0, 45.0, 22.0, 35.0, 50.0, 28.0, 40.0]
    raw_salaries = [50000.0, 60000.0, 90000.0, 45000.0, 70000.0, 95000.0, 55000.0, 80000.0]
    categories = ["junior", "mid", "senior", "junior", "mid", "senior", "junior", "senior"]

    # Numeric features
    norm_ages = normalize(raw_ages)
    std_salaries = standardize(raw_salaries)
    binned_ages = bin_values(raw_ages, n_bins=3)

    # Categorical features
    encoded = one_hot_encode(categories)

    # Pipeline
    pipeline = FeaturePipeline()
    pipeline.add_step("normalize", normalize).add_step("standardize", standardize)
    transformed = pipeline.run(raw_ages)

if __name__ == "__main__":
    main()
