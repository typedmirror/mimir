"""Smoke test: LRU cache with generics, time-based expiry, stats tracking.
Tests: Generic K/V types, Optional, dataclass patterns, dict + list operations,
decorator patterns, numeric operations.
"""
from typing import TypeVar, Generic, Optional, Dict, List, Tuple
import time

K = TypeVar('K')
V = TypeVar('V')

# ---- Cache entry ----

class CacheEntry(Generic[V]):
    def __init__(self, value: V, ttl: float = 0.0) -> None:
        self.value = value
        self.created_at = time.time()
        self.ttl = ttl
        self.access_count: int = 0

    def is_expired(self) -> bool:
        if self.ttl <= 0:
            return False
        return (time.time() - self.created_at) > self.ttl

# ---- LRU Cache ----

class LRUCache(Generic[K, V]):
    def __init__(self, capacity: int, default_ttl: float = 0.0) -> None:
        self.capacity = capacity
        self.default_ttl = default_ttl
        self._store: Dict[K, CacheEntry[V]] = {}
        self._order: List[K] = []
        self._stats = CacheStats()

    def get(self, key: K) -> Optional[V]:
        if key not in self._store:
            self._stats.misses += 1
            return None

        entry = self._store[key]
        if entry.is_expired():
            self._evict(key)
            self._stats.misses += 1
            return None

        entry.access_count += 1
        self._stats.hits += 1

        # Move to end (most recently used)
        self._order.remove(key)
        self._order.append(key)

        return entry.value

    def put(self, key: K, value: V, ttl: float = 0.0) -> None:
        effective_ttl = ttl if ttl > 0 else self.default_ttl

        if key in self._store:
            self._store[key] = CacheEntry(value, effective_ttl)
            self._order.remove(key)
            self._order.append(key)
            return

        # Evict LRU if at capacity
        while len(self._store) >= self.capacity:
            if len(self._order) == 0:
                break
            lru_key = self._order[0]
            self._evict(lru_key)
            self._stats.evictions += 1

        self._store[key] = CacheEntry(value, effective_ttl)
        self._order.append(key)

    def _evict(self, key: K) -> None:
        if key in self._store:
            del self._store[key]
        if key in self._order:
            self._order.remove(key)

    def size(self) -> int:
        return len(self._store)

    def clear(self) -> None:
        self._store.clear()
        self._order.clear()

    def stats(self) -> "CacheStats":
        return self._stats

# ---- Stats ----

class CacheStats:
    def __init__(self) -> None:
        self.hits: int = 0
        self.misses: int = 0
        self.evictions: int = 0

    def hit_rate(self) -> float:
        total = self.hits + self.misses
        if total == 0:
            return 0.0
        return self.hits / total

    def total_requests(self) -> int:
        return self.hits + self.misses

# ---- Decorator ----

def cached(ttl: float = 60.0) -> object:
    """Decorator that caches function results."""
    cache: Dict[str, Tuple[float, object]] = {}

    def decorator(func: object) -> object:
        def wrapper(*args: object) -> object:
            key = str(args)
            if key in cache:
                cached_time, cached_value = cache[key]
                if time.time() - cached_time < ttl:
                    return cached_value
            result = func(*args)
            cache[key] = (time.time(), result)
            return result
        return wrapper
    return decorator

# ---- Main ----

def main() -> None:
    # String cache
    cache: LRUCache[str, int] = LRUCache(capacity=3, default_ttl=10.0)

    cache.put("a", 1)
    cache.put("b", 2)
    cache.put("c", 3)

    val = cache.get("a")  # hit
    cache.put("d", 4)     # evicts "b" (LRU)

    b_val = cache.get("b")  # miss (evicted)

    stats = cache.stats()
    rate = stats.hit_rate()
    total = stats.total_requests()

if __name__ == "__main__":
    main()
