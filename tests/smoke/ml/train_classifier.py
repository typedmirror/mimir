"""Smoke test: ML training pipeline with common patterns.
Tests: type inference, data leakage detection, mutable defaults,
shape analysis, typing generics.
"""
from typing import TypeVar, Generic, Optional, Tuple, List
import math

T = TypeVar('T')

# ---- Data structures ----

class Dataset(Generic[T]):
    def __init__(self, data: List[T], labels: List[int]) -> None:
        self.data = data
        self.labels = labels
        self.size = len(data)

    def split(self, ratio: float) -> Tuple["Dataset[T]", "Dataset[T]"]:
        mid = int(self.size * ratio)
        train = Dataset(self.data[:mid], self.labels[:mid])
        test = Dataset(self.data[mid:], self.labels[mid:])
        return train, test

# ---- Model ----

class LinearModel:
    def __init__(self, input_dim: int, output_dim: int) -> None:
        self.weights: List[List[float]] = [[0.0] * output_dim for _ in range(input_dim)]
        self.bias: List[float] = [0.0] * output_dim

    def forward(self, x: List[float]) -> List[float]:
        output = list(self.bias)
        for i in range(len(output)):
            for j in range(len(x)):
                output[i] += self.weights[j][i] * x[j]
        return output

    def predict(self, x: List[float]) -> int:
        scores = self.forward(x)
        best = 0
        for i in range(len(scores)):
            if scores[i] > scores[best]:
                best = i
        return best

# ---- Training ----

def train_epoch(
    model: LinearModel,
    dataset: Dataset[List[float]],
    lr: float = 0.01,
) -> float:
    total_loss = 0.0
    for i in range(dataset.size):
        x = dataset.data[i]
        y = dataset.labels[i]
        scores = model.forward(x)

        # softmax cross-entropy loss
        max_score = max(scores)
        exp_scores = [math.exp(s - max_score) for s in scores]
        total = sum(exp_scores)
        probs = [e / total for e in exp_scores]
        loss = -math.log(probs[y] + 1e-8)
        total_loss += loss

        # gradient update
        for c in range(len(scores)):
            grad = probs[c] - (1.0 if c == y else 0.0)
            for j in range(len(x)):
                model.weights[j][c] -= lr * grad * x[j]
            model.bias[c] -= lr * grad

    return total_loss / dataset.size

def evaluate(model: LinearModel, dataset: Dataset[List[float]]) -> float:
    correct = 0
    for i in range(dataset.size):
        pred = model.predict(dataset.data[i])
        if pred == dataset.labels[i]:
            correct += 1
    return correct / dataset.size

# ---- Main ----

def main() -> None:
    # Create synthetic dataset
    data: List[List[float]] = [
        [1.0, 0.0], [0.0, 1.0], [1.0, 1.0], [0.0, 0.0],
        [0.8, 0.2], [0.2, 0.8], [0.9, 0.9], [0.1, 0.1],
    ]
    labels = [0, 1, 0, 1, 0, 1, 0, 1]

    dataset = Dataset(data, labels)
    train_set, test_set = dataset.split(0.75)

    model = LinearModel(input_dim=2, output_dim=2)

    for epoch in range(10):
        loss = train_epoch(model, train_set)
        acc = evaluate(model, test_set)

    final_acc = evaluate(model, test_set)

if __name__ == "__main__":
    main()
