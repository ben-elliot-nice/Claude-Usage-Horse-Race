# server/app/store.py
import uuid
from datetime import datetime, timezone
from redis import Redis

TTL = 60 * 24 * 60 * 60  # 60 days in seconds

# Lua script for atomic rename operation.
# Returns "ok", "forbidden", or "conflict".
_RENAME_SCRIPT = """
local slug      = KEYS[1]
local old_name  = ARGV[1]
local new_name  = ARGV[2]
local client_id = ARGV[3]

local names_key = "race:" .. slug .. ":names"

-- Verify ownership of old_name
local owner = redis.call("HGET", names_key, old_name)
if owner == false or owner ~= client_id then
    return "forbidden"
end

-- Atomically claim new_name
local claimed = redis.call("HSETNX", names_key, new_name, client_id)
if claimed == 0 then
    local new_owner = redis.call("HGET", names_key, new_name)
    if new_owner ~= client_id then
        return "conflict"
    end
end

-- Release old_name
redis.call("HDEL", names_key, old_name)

-- Move participant data if it exists
local old_p = "race:" .. slug .. ":p:" .. old_name
local new_p = "race:" .. slug .. ":p:" .. new_name
if redis.call("EXISTS", old_p) == 1 then
    redis.call("RENAME", old_p, new_p)
    redis.call("HSET", new_p, "name", new_name)
end

return "ok"
"""


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


def check_and_reset_epoch(r: Redis, slug: str) -> None:
    """
    Lazy monthly reset. If the current epoch sentinel key is missing,
    clear all participant usage data and create a new sentinel with TTL
    expiring at 00:00 GMT on the 1st of next month.
    The names hash is never touched.
    """
    now = datetime.now(timezone.utc)
    epoch_key = f"race:{slug}:epoch:{now.strftime('%Y-%m')}"

    if r.exists(epoch_key):
        return

    keys: list[bytes] = []
    cursor = 0
    while True:
        cursor, batch = r.scan(cursor, match=f"race:{slug}:p:*", count=100)
        keys.extend(batch)
        if cursor == 0:
            break
    if keys:
        r.delete(*keys)

    if now.month == 12:
        next_month = datetime(now.year + 1, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
    else:
        next_month = datetime(now.year, now.month + 1, 1, 0, 0, 0, tzinfo=timezone.utc)

    ttl_seconds = max(1, int((next_month - now).total_seconds()))
    r.set(epoch_key, "1", ex=ttl_seconds)


def register_name(r: Redis, slug: str, name: str, client_id: str) -> str:
    """
    Claim a display name for a client UUID.
    Returns: "ok" | "no_op" | "conflict"
    """
    result = r.hsetnx(f"race:{slug}:names", name, client_id)
    if result == 1:
        r.expire(f"race:{slug}:names", TTL)
        return "ok"
    existing = r.hget(f"race:{slug}:names", name)
    if existing and existing.decode() == client_id:
        return "no_op"
    return "conflict"


def check_ownership(r: Redis, slug: str, name: str, client_id: str) -> bool:
    """Returns True if client_id is the registered owner of name in this race."""
    owner = r.hget(f"race:{slug}:names", name)
    return owner is not None and owner.decode() == client_id


def upsert_participant(r: Redis, slug: str, payload: dict) -> str:
    """
    Upsert participant usage data after ownership validation.
    Triggers lazy epoch reset before writing.
    Returns: "ok" | "not_found" | "forbidden"
    """
    if not r.exists(f"race:{slug}:meta"):
        return "not_found"

    check_and_reset_epoch(r, slug)

    if not check_ownership(r, slug, payload["name"], payload["id"]):
        return "forbidden"

    p_key = f"race:{slug}:p:{payload['name']}"
    data = {k: v for k, v in payload.items() if k != "id"}
    r.hset(p_key, mapping=data)
    r.expire(p_key, TTL)
    r.expire(f"race:{slug}:meta", TTL)
    return "ok"


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


def rename_participant(r: Redis, slug: str, old_name: str, new_name: str, client_id: str) -> str:
    """
    Atomically rename a participant using a Lua script.
    Returns: "ok" | "not_found" | "forbidden" | "conflict"
    """
    if not r.exists(f"race:{slug}:meta"):
        return "not_found"
    result = r.eval(_RENAME_SCRIPT, 1, slug, old_name, new_name, client_id)
    return result.decode() if isinstance(result, bytes) else result
