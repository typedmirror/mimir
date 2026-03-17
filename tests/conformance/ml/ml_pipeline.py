"""ML002: pipeline ordering — model before preprocessor"""
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression

# BAD: model before scaler
_pipe = Pipeline([  # E
    ("model", LogisticRegression()),
    ("scaler", StandardScaler()),
])
