from typing import assert_type
from mimir.stats import ttest, chi2_test, pearson, linear_regression
from mimir.array import zeros

a = zeros((100,))
b = zeros((100,))

# Hypothesis test
result = ttest(a, b)
assert_type(result.statistic, float)
assert_type(result.p_value, float)

# Chi-square
chi = chi2_test(a)
assert_type(chi.p_value, float)

# Correlation
corr = pearson(a, b)
assert_type(corr.r, float)
assert_type(corr.p_value, float)

# Regression
X = zeros((100, 3))
y = zeros((100,))
reg = linear_regression(X, y)
assert_type(reg.intercept, float)
assert_type(reg.r_squared, float)
