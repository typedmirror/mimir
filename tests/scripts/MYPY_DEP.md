# External dependency: mypy test suite (pinned)

`tests/scripts/mypy_test_runner.py` runs mimir against the mypy unit test
corpus (`test-data/unit/check-*.test`). That corpus is NOT vendored — it is
an external git checkout, and pass-rate numbers are only comparable when
everyone measures against the same commit.

## Pin

| | |
|---|---|
| Path | set `MYPY_DIR` (env var) or pass `--mypy-dir PATH` |
| Repository | `https://github.com/python/mypy.git` |
| Pinned commit | `25b210d2cdf3f5d4e17a96eb7ed25f54456bc631` |
| Baseline at this pin | 2902/6029 runnable cases (48.1%), measured 2026-07-15 |

## Fetch

```sh
git clone --filter=blob:none https://github.com/python/mypy.git <path-of-your-choice>
git -C <path-of-your-choice> checkout 25b210d2cdf3f5d4e17a96eb7ed25f54456bc631
export MYPY_DIR=<path-of-your-choice>
```

(`--filter=blob:none` matches the existing checkout's partial-clone config
and keeps the download small; a full clone works too.)

Set `MYPY_DIR` in your shell profile (or export it before running the
scripts) so `mypy_test_runner.py`, `triage.py`, and `gap_analysis.py` all
pick it up. `--mypy-dir PATH` on any of those scripts overrides `MYPY_DIR`
for a single run. If neither is set, the scripts print this file's fetch
instructions and exit 1 — there is no default path.

## Verify

```sh
git -C "$MYPY_DIR" rev-parse HEAD
# must print 25b210d2cdf3f5d4e17a96eb7ed25f54456bc631
ls "$MYPY_DIR/test-data/unit/" | grep -c '^check-'
# 98 check-*.test files at the pinned commit
```

## Runner behavior

- No checkout resolvable (`MYPY_DIR` unset, `--mypy-dir` not passed, and the
  legacy path absent): the runner exits 1 with a message pointing at this
  file, the `MYPY_DIR` env var, and the fetch commands above.
- Checkout resolved but missing (or `test-data/unit/` absent): same exit-1
  behavior, naming the resolved path.
- Checkout present but at a different commit: the runner prints a warning
  with both hashes and continues — numbers from such a run are NOT
  comparable to the baseline and must not be published against it.

## Why pinned

Upstream mypy edits its test files continuously (cases added, expected
errors reworded, markers moved). The 2902/6029 baseline in the factory
contract and CLAUDE.md is a property of this exact commit; moving the pin
is a deliberate act that re-baselines every number downstream.
