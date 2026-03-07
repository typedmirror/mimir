#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$PROJECT_ROOT/src"
OUT_DIR="$PROJECT_ROOT/build"
BINARY="$OUT_DIR/mimir"

mkdir -p "$OUT_DIR"

MODE="${1:-debug}"

case "$MODE" in
    debug)
        echo "Building mimir (debug)..."
        odin build "$SRC_DIR" -out:"$BINARY" -debug -collection:mimir="$SRC_DIR"
        ;;
    release)
        echo "Building mimir (release)..."
        odin build "$SRC_DIR" -out:"$BINARY" -o:speed -collection:mimir="$SRC_DIR"
        ;;
    test)
        echo "Running mimir tests..."
        odin test "$SRC_DIR" -out:"$OUT_DIR/mimir_test" -debug -collection:mimir="$SRC_DIR"
        ;;
    clean)
        echo "Cleaning build artifacts..."
        rm -rf "$OUT_DIR"
        ;;
    *)
        echo "Usage: ./build.sh [debug|release|test|clean]"
        exit 1
        ;;
esac

echo "Done."
