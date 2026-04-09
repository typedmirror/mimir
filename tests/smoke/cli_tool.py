"""Smoke test: CLI tool with argument parsing, file I/O, error handling.
Tests: Union types, Optional narrowing, match/case, dataclass-like patterns,
exception flow, string processing.
"""
from typing import Optional, List, Union, Literal

# ---- Configuration ----

class Config:
    def __init__(
        self,
        input_path: str,
        output_path: str,
        mode: str = "transform",
        verbose: bool = False,
        max_lines: int = 0,
    ) -> None:
        self.input_path = input_path
        self.output_path = output_path
        self.mode = mode
        self.verbose = verbose
        self.max_lines = max_lines

# ---- Argument parsing ----

def parse_args(argv: List[str]) -> Union[Config, str]:
    """Parse CLI arguments. Returns Config or error message."""
    if len(argv) < 2:
        return "usage: tool <input> <output> [--mode transform|analyze] [--verbose] [--max-lines N]"

    input_path = argv[0]
    output_path = argv[1]
    mode = "transform"
    verbose = False
    max_lines = 0

    i = 2
    while i < len(argv):
        arg = argv[i]
        if arg == "--mode":
            if i + 1 >= len(argv):
                return "--mode requires an argument"
            mode = argv[i + 1]
            if mode != "transform" and mode != "analyze":
                return f"unknown mode: {mode}"
            i += 2
        elif arg == "--verbose":
            verbose = True
            i += 1
        elif arg == "--max-lines":
            if i + 1 >= len(argv):
                return "--max-lines requires a number"
            max_lines = int(argv[i + 1])
            i += 2
        else:
            return f"unknown argument: {arg}"

    return Config(input_path, output_path, mode, verbose, max_lines)

# ---- Text processing ----

class LineStats:
    def __init__(self) -> None:
        self.total_lines: int = 0
        self.blank_lines: int = 0
        self.max_length: int = 0
        self.total_chars: int = 0
        self.word_count: int = 0

    def avg_length(self) -> float:
        if self.total_lines == 0:
            return 0.0
        return self.total_chars / self.total_lines

def analyze_text(lines: List[str]) -> LineStats:
    stats = LineStats()
    for line in lines:
        stats.total_lines += 1
        stats.total_chars += len(line)
        if len(line.strip()) == 0:
            stats.blank_lines += 1
        if len(line) > stats.max_length:
            stats.max_length = len(line)
        stats.word_count += len(line.split())
    return stats

def transform_text(lines: List[str], config: Config) -> List[str]:
    result: List[str] = []
    for i, line in enumerate(lines):
        if config.max_lines > 0 and i >= config.max_lines:
            break
        # Strip trailing whitespace
        cleaned = line.rstrip()
        # Normalize tabs to spaces
        cleaned = cleaned.replace("\t", "    ")
        result.append(cleaned)
    return result

# ---- I/O helpers ----

def read_lines(path: str) -> Optional[List[str]]:
    """Read file lines, return None on error."""
    try:
        with open(path, "r") as f:
            return f.readlines()
    except (FileNotFoundError, PermissionError):
        return None

def write_lines(path: str, lines: List[str]) -> bool:
    """Write lines to file, return success."""
    try:
        with open(path, "w") as f:
            for line in lines:
                f.write(line + "\n")
        return True
    except (PermissionError, OSError):
        return False

# ---- Main ----

def main(argv: List[str]) -> int:
    result = parse_args(argv)

    # Union narrowing
    if isinstance(result, str):
        print(result)
        return 1

    config: Config = result

    lines = read_lines(config.input_path)
    if lines is None:
        print(f"error: cannot read {config.input_path}")
        return 1

    if config.mode == "analyze":
        stats = analyze_text(lines)
        print(f"Lines: {stats.total_lines}")
        print(f"Words: {stats.word_count}")
        print(f"Avg length: {stats.avg_length():.1f}")
        return 0

    # transform mode
    output = transform_text(lines, config)
    if not write_lines(config.output_path, output):
        print(f"error: cannot write {config.output_path}")
        return 1

    if config.verbose:
        print(f"Processed {len(output)} lines")

    return 0
