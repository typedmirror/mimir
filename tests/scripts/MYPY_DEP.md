# External dependency: mypy test suite (pinned)

`tests/scripts/mypy_test_runner.py` runs mimir against the mypy unit test
corpus (`test-data/unit/check-*.test`). That corpus is NOT vendored — it is
an external git checkout, and pass-rate numbers are only comparable when
everyone measures against the same commit.

## Pin

| | |
|---|---|
| Required path (runner default) | `/Users/ivermektin/Desktop/mypy` |
| Repository | `https://github.com/python/mypy.git` |
| Pinned commit | `25b210d2cdf3f5d4e17a96eb7ed25f54456bc631` |
| Baseline at this pin | 2902/6029 runnable cases (48.1%), measured 2026-07-15 |

## Fetch

```sh
git clone --filter=blob:none https://github.com/python/mypy.git /Users/ivermektin/Desktop/mypy
git -C /Users/ivermektin/Desktop/mypy checkout 25b210d2cdf3f5d4e17a96eb7ed25f54456bc631
```

(`--filter=blob:none` matches the existing checkout's partial-clone config
and keeps the download small; a full clone works too.)

A different location works via `--mypy-dir PATH`, but CI/baseline numbers
assume the default path above.

## Verify

```sh
git -C /Users/ivermektin/Desktop/mypy rev-parse HEAD
# must print 25b210d2cdf3f5d4e17a96eb7ed25f54456bc631
ls /Users/ivermektin/Desktop/mypy/test-data/unit/ | grep -c '^check-'
# 98 check-*.test files at the pinned commit
```

## Runner behavior

- Checkout missing (or `test-data/unit/` absent): the runner exits 1 with a
  message pointing at this file and the fetch commands above.
- Checkout present but at a different commit: the runner prints a warning
  with both hashes and continues — numbers from such a run are NOT
  comparable to the baseline and must not be published against it.

## Why pinned

Upstream mypy edits its test files continuously (cases added, expected
errors reworded, markers moved). The 2902/6029 baseline in the factory
contract and CLAUDE.md is a property of this exact commit; moving the pin
is a deliberate act that re-baselines every number downstream.
