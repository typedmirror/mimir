from typing import TypedDict
from mimir.data import read_csv

class Config(TypedDict):
    host: str
    port: int

df = read_csv("config.csv", Config)
x = df["hst"]  # E: DATA001
y = df["nonexistent"]  # E: DATA001

bad = read_csv("data.csv", int)  # E: DATA002
