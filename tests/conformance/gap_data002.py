from mimir.data import read_csv

df = read_csv("data.csv", int)  # E[DATA002]: passing a non-TypedDict type as schema argument
