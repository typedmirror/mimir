# mimir

A complete Python development platform in a single native binary. Replaces mypy, pip, pytest, black, ruff, bandit, and more.

Written in [Odin](https://odin-lang.org/). ~52K lines. Zero dependencies at runtime.

**Status: Alpha.** Core architecture is sound. Type system handles most Python patterns. Real-world usability improving rapidly.

## What it does

```
mimir check .          # Type check (like mypy, but faster)
mimir lint .           # Lint (like ruff)
mimir format .         # Format (like black)
mimir test .           # Run tests (like pytest)
mimir run script.py    # Run with auto-deps (like pipx)
mimir audit .          # Security analysis (like bandit)
mimir safety .         # Error handling analysis
mimir perf .           # Performance analysis
mimir repl             # Type-aware REPL
mimir lsp              # Language server
```

One binary. Zero configuration. No virtual environments.

## Install

Build from source (requires Odin compiler):

```bash
git clone https://github.com/user/mimir.git
cd mimir
odin build src/ -collection:mimir=src/ -out:mimir -o:speed
```

### First run

```bash
# Download stdlib type stubs (one-time, ~30s)
mimir stubs fetch

# Check a project
mimir check .
```

## Examples

### Type checking

```bash
# Check a single file
mimir check app.py

# Check a project (auto-detects project root)
mimir check src/myapp/main.py    # finds .git/pyproject.toml, checks whole project

# Check with confidence filtering
mimir check . --min-confidence high
```

### Package management

```bash
# Add a dependency
mimir add requests

# Install from mimir.toml
mimir install

# Run a script with inline deps (PEP 723)
mimir run script.py
```

### Code transformation

```bash
# Auto-add return type annotations
mimir codemod add-return-types .

# Modernize type hints (List[int] -> list[int])
mimir codemod modernize-annotations .

# Remove unused imports
mimir codemod remove-unused-imports .
```

### Analysis

```bash
# Security audit
mimir audit .

# Performance analysis
mimir perf .

# Dependency analysis
mimir deps .
```

## Key features

- **Type inference**: Forward inference with constraint-based backfill for unannotated code
- **160+ diagnostic codes**: T001-T012, F001-F002, D001, L001-L011, SEC001-SEC014, CONC001-CONC008, PERF001-PERF010, SAF001-SAF012, and more
- **Zero config**: Works out of the box. Optional `mimir.toml` for customization
- **Auto-dependency resolution**: Scans installed packages automatically — no stub management needed
- **GPU compilation**: `mimir compile-gpu` emits WGSL/MSL/PTX/SPIR-V kernels from Python tensor code
- **WASM compilation**: `mimir compile-wasm` for browser deployment
- **42+ CLI commands**: check, lint, format, test, run, audit, safety, perf, repl, lsp, codemod, and more

## Diagnostic levels

```bash
mimir check . --level basic       # Type errors only
mimir check . --level inference   # + inferred type issues
mimir check . --level security    # + security rules
mimir check . --level strict      # Everything (default)
```

## Inline suppression

```python
x = foo()  # mimir: ignore
y = bar()  # mimir: ignore[T007]
```

## Configuration

Optional `mimir.toml`:

```toml
[project]
name = "myapp"
python = ">=3.10"

[dependencies]
requests = ">=2.28"
flask = ">=3.0"

[analysis]
level = "strict"
```

## Architecture

Single constraint graph — type inference, taint analysis, security scanning, performance analysis, and GPU compilation are all queries against the same model.

```
Source → Parser → Binder → Flow (CFG+DFG) → Type Checker → [All Analyses]
```

Arena-allocated per analysis pass. No GC. Native speed.

## License

MIT
