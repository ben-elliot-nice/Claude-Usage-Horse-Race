# server/app/dependencies.py
from __future__ import annotations
import os
from redis import Redis

_redis: Redis | None = None


def get_redis() -> Redis:
    assert _redis is not None, "Redis not initialised — call init_redis() first"
    return _redis


def init_redis(url: str | None = None) -> Redis:
    global _redis
    _redis = Redis.from_url(url or os.environ.get("REDIS_URL", "redis://localhost:6379"))
    return _redis


def close_redis() -> None:
    global _redis
    if _redis:
        _redis.close()
        _redis = None
