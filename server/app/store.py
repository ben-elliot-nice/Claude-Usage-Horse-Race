# server/app/store.py
import uuid
from datetime import datetime, timezone
from redis import Redis

TTL = 60 * 24 * 60 * 60  # 60 days in seconds


def create_race(r: Redis, name: str) -> str:
    """Create a new race and return its UUID slug."""
    slug = str(uuid.uuid4())
    r.hset(f"race:{slug}:meta", mapping={
        "name": name,
        "created_at": datetime.now(timezone.utc).isoformat(),
    })
    r.expire(f"race:{slug}:meta", TTL)
    return slug


def get_race_name(r: Redis, slug: str) -> str | None:
    """Return the race display name, or None if the race does not exist."""
    val = r.hget(f"race:{slug}:meta", "name")
    return val.decode() if val else None


def upsert_participant(r: Redis, slug: str, payload: dict) -> bool:
    """Upsert a participant and refresh TTLs. Returns False if race not found."""
    if not r.exists(f"race:{slug}:meta"):
        return False
    p_key = f"race:{slug}:p:{payload['name']}"
    r.hset(p_key, mapping=payload)
    r.expire(p_key, TTL)
    r.expire(f"race:{slug}:meta", TTL)
    return True


def get_participants(r: Redis, slug: str) -> list[dict]:
    """SCAN for all participant keys and fetch via pipeline. Never uses KEYS."""
    keys: list[bytes] = []
    cursor = 0
    while True:
        cursor, batch = r.scan(cursor, match=f"race:{slug}:p:*", count=100)
        keys.extend(batch)
        if cursor == 0:
            break
    if not keys:
        return []
    pipe = r.pipeline()
    for key in keys:
        pipe.hgetall(key)
    results = pipe.execute()
    return [
        {k.decode(): v.decode() for k, v in raw.items()}
        for raw in results
        if raw
    ]


def sorted_standings(participants: list[dict]) -> list[dict]:
    """Sort participants by cost_used/cost_limit descending."""
    def pct(p: dict) -> float:
        limit = int(p.get("cost_limit_cents", 1))
        used = int(p.get("cost_used_cents", 0))
        return used / limit if limit > 0 else 0.0
    return sorted(participants, key=pct, reverse=True)
