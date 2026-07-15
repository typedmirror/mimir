"""PERF005: N+1 query pattern — database query inside loop"""
import sqlite3

def get_orders(users):
    conn = sqlite3.connect("app.db")
    cursor = conn.cursor()
    for user in users:
        cursor.execute("SELECT * FROM orders WHERE user_id = ?", (user.id,))  # E[PERF005]
