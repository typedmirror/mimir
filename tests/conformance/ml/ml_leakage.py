"""ML001: data leakage — fit_transform before train_test_split"""
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split

X = [[1, 2], [3, 4], [5, 6], [7, 8]]
y = [0, 1, 0, 1]

# BAD: fit on all data, then split
scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)
X_train, X_test = train_test_split(X_scaled)  # E[ML001]

# GOOD: split first (no error)
X_train2, X_test2 = train_test_split(X)
X_train_scaled = scaler.fit_transform(X_train2)

# BAD: two-step fit + transform before split
scaler2 = StandardScaler()
scaler2.fit(X)
X_transformed = scaler2.transform(X)
X_a, X_b = train_test_split(X_transformed)  # E[ML001]
