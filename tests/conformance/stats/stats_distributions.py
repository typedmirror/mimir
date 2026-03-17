from typing import assert_type
from mimir.stats import Normal, Uniform, Binomial, Poisson, Beta

# Continuous distribution
dist = Normal(mean=0.0, std=1.0)
samples = dist.sample(1000)
p = dist.pdf(1.96)
assert_type(p, float)
c = dist.cdf(1.96)
assert_type(c, float)
q = dist.ppf(0.975)
assert_type(q, float)
m = dist.mean()
assert_type(m, float)
s = dist.std()
assert_type(s, float)

# Other continuous
u = Uniform(low=0.0, high=1.0)
us = u.sample(100)
b = Beta(a=2.0, b=5.0)
bp = b.pdf(0.5)
assert_type(bp, float)

# Discrete distribution
binom = Binomial(n=10, p=0.5)
bs = binom.sample(100)
prob = binom.pmf(5)
assert_type(prob, float)

pois = Poisson(lam=3.0)
ps = pois.sample(100)
