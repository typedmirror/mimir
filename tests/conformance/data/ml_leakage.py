"""ML pipeline: data leakage detection — fit before split."""

from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from mimir.array import zeros

# BAD: fit_transform on ALL data before splitting
X = zeros((100, 10))
scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)
X_train, X_test = train_test_split(X_scaled)  # E[ML001]: data leakage
