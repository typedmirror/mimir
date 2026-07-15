"""ML002: pipeline ordering — model before preprocessor"""
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression

# BAD: model before scaler
_bad = Pipeline([  # E[ML002]
    ("model", LogisticRegression()),
    ("scaler", StandardScaler()),
])

# GOOD: scaler before model (no error)
_good = Pipeline([
    ("scaler", StandardScaler()),
    ("model", LogisticRegression()),
])
