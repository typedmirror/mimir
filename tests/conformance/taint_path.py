"""Taint analysis: path traversal (SEC014)"""
import sys

# sys.argv → open
path = sys.argv[1]
open(path)              # SEC014: sys.argv → open()

# input → open
user_path = input("File: ")
open(user_path)         # SEC014: input() → open()

# Literal — should NOT flag
open("config.txt")      # OK — literal, never tainted
