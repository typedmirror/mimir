"""ML001: data leakage — fit_transform before train_test_split"""
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split

X = [[1, 2], [3, 4], [5, 6], [7, 8]]
y = [0, 1, 0, 1]

# BAD: fit on all data, then split
scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)
X_train, X_test = train_test_split(X_scaled)  # E
