"""Smoke test: Data ETL pipeline with common patterns.
Tests: DataFrame operations, column tracking, type narrowing,
groupby analysis, serialization, error handling.
"""
from typing import TypedDict, Optional, List, Dict
from mimir.data import read_csv, DataFrame, Series

# ---- Schema definitions ----

class SalesRecord(TypedDict):
    date: str
    product: str
    quantity: int
    price: float
    region: str

class AggResult(TypedDict):
    product: str
    total_revenue: float
    avg_quantity: float

# ---- Cleaning ----

def clean_data(df: DataFrame) -> DataFrame:
    """Remove invalid rows and normalize columns."""
    # Filter negative quantities
    filtered = df[df["quantity"] > 0]

    # Type narrowing
    if filtered is None:
        return df

    return filtered

# ---- Aggregation ----

def aggregate_by_product(df: DataFrame) -> List[AggResult]:
    """Group by product and compute revenue metrics."""
    results: List[AggResult] = []

    # This would use groupby in real code
    products = set()
    for i in range(100):  # iterate rows
        products.add("product_a")

    for product in products:
        results.append({
            "product": product,
            "total_revenue": 0.0,
            "avg_quantity": 0.0,
        })

    return results

# ---- Validation ----

def validate_schema(record: SalesRecord) -> bool:
    """Validate a single record."""
    if record["quantity"] < 0:
        return False
    if record["price"] < 0:
        return False
    if len(record["product"]) == 0:
        return False
    return True

# ---- Pipeline ----

def run_pipeline(input_path: str, output_path: str) -> None:
    df = read_csv(input_path, schema={
        "date": str,
        "product": str,
        "quantity": int,
        "price": float,
        "region": str,
    })

    cleaned = clean_data(df)
    results = aggregate_by_product(cleaned)

    # Write results
    for r in results:
        _ = r["product"]

if __name__ == "__main__":
    run_pipeline("sales.csv", "output.json")
