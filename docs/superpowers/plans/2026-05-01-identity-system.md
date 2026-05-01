# Race Identity System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a private UUID identity layer to the horse race server and client so name collisions are impossible, only the identity holder can push data under their name, and names are claimed atomically with monthly reset support.

**Architecture:** Server gains a `race:{slug}:names` hash (name→uuid ownership registry), epoch sentinel key for lazy monthly reset, two new endpoints (register, rename), and validates `id` on every PUT. Client generates a persistent UUID on first use, registers before pushing, and calls the rename API when the display name changes.

**Tech Stack:** Python/FastAPI/Redis (server), Swift/SwiftUI (macOS client), fakeredis + pytest, XCTest.

---

## Working Directories

- Server: `/Users/Ben.Elliot/repos/claude-usage-horse-race/server/`
- Swift: `/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage/`
- Run server tests: `cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server && source .venv/bin/activate && pytest -v`
- Build Swift: `xcodebuild build -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" -scheme "Claude Usage" -destination "platform=macOS,arch=arm64" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | grep -E "^(error:|BUILD)" | tail -5`

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `server/app/models.py` | Modify | Add `id` to `ParticipantPayload`; add `RegisterRequest`, `RenameRequest` |
| `server/app/store.py` | Modify | Add `check_and_reset_epoch`, `register_name`, `check_ownership`, `rename_participant` (Lua); update `upsert_participant` to validate ownership and return string |
| `server/app/routes.py` | Modify | Add `POST /register`, `POST /participant/rename`; update `PUT /participant` |
| `server/tests/test_store.py` | Modify | Fix 3 broken existing tests + add 16 new tests |
| `server/tests/test_routes.py` | Modify | Fix 5 broken existing tests + add 7 new tests |
| `Claude Usage/Shared/Storage/RaceSettings.swift` | Modify | Add `participantID: String` (auto-generated UUID, persisted) |
| `Claude Usage/Shared/Services/RaceService.swift` | Modify | Add `register()`, add `id` to `push()` payload, handle 403/409 |
| `Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift` | Modify | Trigger rename API on name submit; show inline 409 error |
| `Claude UsageTests/RaceSettingsTests.swift` | Modify | Add `test_participantID_generated_once` |

---

## Task 1: Server Models

**Files:**
- Modify: `server/app/models.py`

No tests for this task — models are exercised by route tests in Task 3. Build verification is implicit (syntax errors would fail subsequent task's import).

- [ ] **Step 1: Update `server/app/models.py`**

Replace the entire file contents:

```python
# server/app/models.py
from pydantic import BaseModel, field_validator


class CreateRaceRequest(BaseModel):
    name: str


class CreateRaceResponse(BaseModel):
    slug: str
    name: str


class RegisterRequest(BaseModel):
    id: str
    name: str

    @field_validator("name")
    @classmethod
    def name_no_colon(cls, v: str) -> str:
        if ":" in v:
            raise ValueError("name may not contain ':'")
        return v


class RenameRequest(BaseModel):
    id: str
    old_name: str
    new_name: str

    @field_validator("old_name", "new_name")
    @classmethod
    def name_no_colon(cls, v: str) -> str:
        if ":" in v:
            raise ValueError("name may not contain ':'")
        return v


class ParticipantPayload(BaseModel):
    id: str
    name: str
    cost_used_cents: int
    cost_limit_cents: int
    updated_at: str  # ISO 8601 string — stored verbatim, validated client-side

    @field_validator("name")
    @classmethod
    def name_no_colon(cls, v: str) -> str:
        if ":" in v:
            raise ValueError("participant name may not contain ':'")
        return v


class Participant(BaseModel):
    name: str
    cost_used_cents: int
    cost_limit_cents: int
    updated_at: str


class StandingsResponse(BaseModel):
    race_slug: str
    name: str
    participants: list[Participant]
```

- [ ] **Step 2: Verify import**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
source .venv/bin/activate
python -c "from app.models import RegisterRequest, RenameRequest, ParticipantPayload; print('OK')"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add server/app/models.py
git commit -m "feat: Add RegisterRequest, RenameRequest; add id to ParticipantPayload"
```

---

## Task 2: Server Store — Identity Functions

**Files:**
- Modify: `server/app/store.py`
- Modify: `server/tests/test_store.py`

This task updates `upsert_participant` (breaking change: returns `str` not `bool`) and adds 5 new store functions. Write tests first, then implement.

- [ ] **Step 1: Write failing tests — replace `server/tests/test_store.py` entirely**

```python
# server/tests/test_store.py
import fakeredis
import pytest
from datetime import datetime, timezone
from app.store import (
    TTL,
    check_and_reset_epoch,
    check_ownership,
    create_race,
    get_participants,
    get_race_name,
    register_name,
    rename_participant,
    sorted_standings,
    upsert_participant,
)


@pytest.fixture
def r():
    return fakeredis.FakeRedis()


# ── create_race ──────────────────────────────────────────────────────────────

def test_create_race_returns_uuid_slug(r):
    slug = create_race(r, "NICE-TEAM")
    assert len(slug) == 36
    assert slug.count("-") == 4


def test_create_race_stores_name(r):
    slug = create_race(r, "NICE-TEAM")
    assert get_race_name(r, slug) == "NICE-TEAM"


def test_create_race_sets_ttl(r):
    slug = create_race(r, "TEST")
    ttl = r.ttl(f"race:{slug}:meta")
    assert 0 < ttl <= TTL


def test_get_race_name_missing_returns_none(r):
    assert get_race_name(r, "no-such-slug") is None


# ── check_and_reset_epoch ────────────────────────────────────────────────────

def test_epoch_creates_sentinel_key(r):
    slug = create_race(r, "TEST")
    check_and_reset_epoch(r, slug)
    now = datetime.now(timezone.utc)
    key = f"race:{slug}:epoch:{now.strftime('%Y-%m')}"
    assert r.exists(key)


def test_epoch_sentinel_has_ttl(r):
    slug = create_race(r, "TEST")
    check_and_reset_epoch(r, slug)
    now = datetime.now(timezone.utc)
    key = f"race:{slug}:epoch:{now.strftime('%Y-%m')}"
    assert r.ttl(key) > 0


def test_epoch_clears_participant_data(r):
    slug = create_race(r, "TEST")
    # Seed participant without going through epoch check
    r.hset(f"race:{slug}:p:Ben", mapping={
        "name": "Ben", "cost_used_cents": "100",
        "cost_limit_cents": "1000", "updated_at": "t",
    })
    # No epoch key → reset fires
    check_and_reset_epoch(r, slug)
    assert not r.exists(f"race:{slug}:p:Ben")


def test_epoch_preserves_names_hash(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    check_and_reset_epoch(r, slug)
    assert r.hget(f"race:{slug}:names", "Ben").decode() == "uuid-1"


def test_epoch_noop_when_sentinel_exists(r):
    slug = create_race(r, "TEST")
    check_and_reset_epoch(r, slug)  # creates sentinel
    r.hset(f"race:{slug}:p:Ben", mapping={"name": "Ben"})
    check_and_reset_epoch(r, slug)  # should not clear
    assert r.exists(f"race:{slug}:p:Ben")


# ── register_name ────────────────────────────────────────────────────────────

def test_register_name_ok(r):
    slug = create_race(r, "TEST")
    assert register_name(r, slug, "Ben", "uuid-1") == "ok"


def test_register_name_noop_same_id(r):
    slug = create_race(r, "TEST")
    register_name(r, slug, "Ben", "uuid-1")
    assert register_name(r, slug, "Ben", "uuid-1") == "no_op"


def test_register_name_conflict_different_id(r):
    slug = create_race(r, "TEST")
    register_name(r, slug, "Ben", "uuid-1")
    assert register_name(r, slug, "Ben", "uuid-2") == "conflict"


def test_register_name_sets_ttl(r):
    slug = create_race(r, "TEST")
    register_name(r, slug, "Ben", "uuid-1")
    assert r.ttl(f"race:{slug}:names") > 0


# ── check_ownership ───────────────────────────────────────────────────────────

def test_check_ownership_true(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    assert check_ownership(r, slug, "Ben", "uuid-1") is True


def test_check_ownership_false_wrong_id(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    assert check_ownership(r, slug, "Ben", "uuid-2") is False


def test_check_ownership_false_missing(r):
    slug = create_race(r, "TEST")
    assert check_ownership(r, slug, "Ben", "uuid-1") is False


# ── upsert_participant (updated) ──────────────────────────────────────────────

def test_upsert_participant_not_found(r):
    result = upsert_participant(r, "no-such-race", {
        "id": "uuid-1", "name": "Ben",
        "cost_used_cents": "100", "cost_limit_cents": "1000",
        "updated_at": "2026-05-01T00:00:00Z",
    })
    assert result == "not_found"


def test_upsert_participant_forbidden(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-other")
    result = upsert_participant(r, slug, {
        "id": "uuid-1", "name": "Ben",
        "cost_used_cents": "100", "cost_limit_cents": "1000",
        "updated_at": "2026-05-01T00:00:00Z",
    })
    assert result == "forbidden"


def test_upsert_participant_ok(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    result = upsert_participant(r, slug, {
        "id": "uuid-1", "name": "Ben",
        "cost_used_cents": "42300", "cost_limit_cents": "100000",
        "updated_at": "2026-05-01T14:00:00Z",
    })
    assert result == "ok"


def test_upsert_participant_stores_data(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    upsert_participant(r, slug, {
        "id": "uuid-1", "name": "Ben",
        "cost_used_cents": "42300", "cost_limit_cents": "100000",
        "updated_at": "2026-05-01T14:00:00Z",
    })
    participants = get_participants(r, slug)
    assert len(participants) == 1
    assert participants[0]["name"] == "Ben"
    assert participants[0]["cost_used_cents"] == "42300"


def test_upsert_participant_does_not_store_id_in_p_hash(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    upsert_participant(r, slug, {
        "id": "uuid-1", "name": "Ben",
        "cost_used_cents": "100", "cost_limit_cents": "1000",
        "updated_at": "t",
    })
    data = r.hgetall(f"race:{slug}:p:Ben")
    assert b"id" not in data


def test_upsert_participant_refreshes_meta_ttl(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    r.expire(f"race:{slug}:meta", 100)
    upsert_participant(r, slug, {
        "id": "uuid-1", "name": "Ben",
        "cost_used_cents": "100", "cost_limit_cents": "1000",
        "updated_at": "t",
    })
    assert r.ttl(f"race:{slug}:meta") > 100
    p_ttl = r.ttl(f"race:{slug}:p:Ben")
    assert 0 < p_ttl <= TTL


def test_get_participants_empty(r):
    slug = create_race(r, "EMPTY")
    assert get_participants(r, slug) == []


# ── sorted_standings ──────────────────────────────────────────────────────────

def test_sorted_standings_orders_by_percent_descending(r):
    unsorted = [
        {"name": "Carol", "cost_used_cents": "18000", "cost_limit_cents": "100000", "updated_at": "t"},
        {"name": "Alice", "cost_used_cents": "61500", "cost_limit_cents": "100000", "updated_at": "t"},
        {"name": "Ben",   "cost_used_cents": "42300", "cost_limit_cents": "100000", "updated_at": "t"},
    ]
    result = sorted_standings(unsorted)
    assert result[0]["name"] == "Alice"
    assert result[1]["name"] == "Ben"
    assert result[2]["name"] == "Carol"


def test_sorted_standings_zero_limit_no_crash(r):
    participants = [{"name": "Dave", "cost_used_cents": "100", "cost_limit_cents": "0", "updated_at": "t"}]
    result = sorted_standings(participants)
    assert result[0]["name"] == "Dave"
    assert len(result) == 1


# ── rename_participant ────────────────────────────────────────────────────────

def test_rename_participant_ok(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    r.hset(f"race:{slug}:p:Ben", mapping={
        "name": "Ben", "cost_used_cents": "100",
        "cost_limit_cents": "1000", "updated_at": "t",
    })
    result = rename_participant(r, slug, "Ben", "Benjamin", "uuid-1")
    assert result == "ok"
    assert r.hget(f"race:{slug}:names", "Benjamin").decode() == "uuid-1"
    assert not r.hexists(f"race:{slug}:names", "Ben")
    assert r.hget(f"race:{slug}:p:Benjamin", "name").decode() == "Benjamin"
    assert not r.exists(f"race:{slug}:p:Ben")


def test_rename_participant_forbidden(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-other")
    assert rename_participant(r, slug, "Ben", "Benjamin", "uuid-1") == "forbidden"


def test_rename_participant_conflict(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    r.hset(f"race:{slug}:names", "Benjamin", "uuid-other")
    assert rename_participant(r, slug, "Ben", "Benjamin", "uuid-1") == "conflict"


def test_rename_participant_not_found(r):
    assert rename_participant(r, "no-slug", "Ben", "Benjamin", "uuid-1") == "not_found"
```

- [ ] **Step 2: Run tests — expect failures**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
source .venv/bin/activate
pytest tests/test_store.py -v 2>&1 | grep -E "(PASSED|FAILED|ERROR|ImportError)" | head -20
```

Expected: ImportErrors for `check_and_reset_epoch`, `register_name`, etc.

- [ ] **Step 3: Write the updated `server/app/store.py`**

```python
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
    clear all participant usage data and create a new sentinel with a TTL
    that expires at 00:00 GMT on the 1st of next month.
    The names hash is never touched.
    """
    now = datetime.now(timezone.utc)
    epoch_key = f"race:{slug}:epoch:{now.strftime('%Y-%m')}"

    if r.exists(epoch_key):
        return  # No reset needed

    # Delete all participant data keys
    keys: list[bytes] = []
    cursor = 0
    while True:
        cursor, batch = r.scan(cursor, match=f"race:{slug}:p:*", count=100)
        keys.extend(batch)
        if cursor == 0:
            break
    if keys:
        r.delete(*keys)

    # Create sentinel expiring at 00:00 GMT on 1st of next month
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
    # Name already registered — idempotent if same id
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
    # Store usage data — exclude id (not needed in p hash)
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
```

- [ ] **Step 4: Run store tests — expect pass**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
source .venv/bin/activate
pytest tests/test_store.py -v
```

Expected: `33 passed` (or similar — count all tests in the file).

- [ ] **Step 5: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add server/app/store.py server/tests/test_store.py
git commit -m "feat: Add identity store functions (register, epoch reset, rename Lua)"
```

---

## Task 3: Server Routes

**Files:**
- Modify: `server/app/routes.py`
- Modify: `server/tests/test_routes.py`

Add `POST /register` and `POST /participant/rename`. Update `PUT /participant` to pass `id` and handle new return values. Update `GET /standings` to trigger epoch reset. Fix broken existing route tests and add new ones.

- [ ] **Step 1: Write the full updated `server/tests/test_routes.py`**

```python
# server/tests/test_routes.py
import fakeredis
import pytest
from fastapi.testclient import TestClient

from app.dependencies import get_redis
from app.main import app


@pytest.fixture(autouse=True)
def fake_redis():
    """Override the get_redis dependency with fakeredis for every test."""
    fake_r = fakeredis.FakeRedis()
    app.dependency_overrides[get_redis] = lambda: fake_r
    yield
    app.dependency_overrides.clear()


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


# ── Health ────────────────────────────────────────────────────────────────────

def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


# ── POST /races ───────────────────────────────────────────────────────────────

def test_create_race_returns_201(client):
    resp = client.post("/races", json={"name": "NICE-TEAM"})
    assert resp.status_code == 201


def test_create_race_returns_slug_and_name(client):
    resp = client.post("/races", json={"name": "NICE-TEAM"})
    data = resp.json()
    assert data["name"] == "NICE-TEAM"
    assert len(data["slug"]) == 36


def test_create_race_missing_name_returns_422(client):
    resp = client.post("/races", json={})
    assert resp.status_code == 422


# ── POST /races/{slug}/register ───────────────────────────────────────────────

def test_register_returns_200(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    resp = client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_register_idempotent_same_id(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    resp = client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    assert resp.status_code == 200


def test_register_conflict_different_id(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    resp = client.post(f"/races/{slug}/register", json={"id": "uuid-2", "name": "Ben"})
    assert resp.status_code == 409
    assert resp.json()["detail"] == "Name taken"


def test_register_unknown_race_returns_404(client):
    resp = client.post("/races/nonexistent/register", json={"id": "uuid-1", "name": "Ben"})
    assert resp.status_code == 404


def test_register_name_with_colon_returns_422(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    resp = client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "fo:bar"})
    assert resp.status_code == 422


# ── PUT /races/{slug}/participant ─────────────────────────────────────────────

def _put(client, slug, id_, name, used=42300, limit=100000):
    return client.put(f"/races/{slug}/participant", json={
        "id": id_, "name": name,
        "cost_used_cents": used,
        "cost_limit_cents": limit,
        "updated_at": "2026-05-01T14:00:00Z",
    })


def test_put_participant_returns_200(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    resp = _put(client, slug, "uuid-1", "Ben")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_put_participant_unknown_race_returns_404(client):
    resp = _put(client, "nonexistent", "uuid-1", "Ben")
    assert resp.status_code == 404


def test_put_participant_wrong_id_returns_403(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    resp = _put(client, slug, "uuid-WRONG", "Ben")
    assert resp.status_code == 403
    assert resp.json()["detail"] == "ID does not match name owner"


def test_put_participant_missing_field_returns_422(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    resp = client.put(f"/races/{slug}/participant", json={
        "name": "Ben", "cost_used_cents": 42300,
        # missing id, cost_limit_cents, updated_at
    })
    assert resp.status_code == 422


# ── GET /races/{slug}/standings ───────────────────────────────────────────────

def test_get_standings_empty_race(client):
    slug = client.post("/races", json={"name": "EMPTY"}).json()["slug"]
    resp = client.get(f"/races/{slug}/standings")
    assert resp.status_code == 200
    data = resp.json()
    assert data["name"] == "EMPTY"
    assert data["race_slug"] == slug
    assert data["participants"] == []


def test_get_standings_sorted_descending(client):
    slug = client.post("/races", json={"name": "SORTED"}).json()["slug"]
    for uid, name, used in [
        ("u1", "Carol", 18000), ("u2", "Alice", 61500), ("u3", "Ben", 42300)
    ]:
        client.post(f"/races/{slug}/register", json={"id": uid, "name": name})
        _put(client, slug, uid, name, used=used)
    resp = client.get(f"/races/{slug}/standings")
    participants = resp.json()["participants"]
    assert participants[0]["name"] == "Alice"
    assert participants[1]["name"] == "Ben"
    assert participants[2]["name"] == "Carol"


def test_get_standings_unknown_race_returns_404(client):
    resp = client.get("/races/nonexistent/standings")
    assert resp.status_code == 404


def test_get_standings_participant_fields(client):
    slug = client.post("/races", json={"name": "FIELDS"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Alice"})
    client.put(f"/races/{slug}/participant", json={
        "id": "uuid-1", "name": "Alice",
        "cost_used_cents": 61500, "cost_limit_cents": 100000,
        "updated_at": "2026-05-01T14:20:00Z",
    })
    resp = client.get(f"/races/{slug}/standings")
    p = resp.json()["participants"][0]
    assert p["name"] == "Alice"
    assert p["cost_used_cents"] == 61500
    assert p["cost_limit_cents"] == 100000
    assert p["updated_at"] == "2026-05-01T14:20:00Z"


# ── POST /races/{slug}/participant/rename ─────────────────────────────────────

def _rename(client, slug, id_, old, new):
    return client.post(f"/races/{slug}/participant/rename", json={
        "id": id_, "old_name": old, "new_name": new,
    })


def test_rename_returns_200(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    _put(client, slug, "uuid-1", "Ben")
    resp = _rename(client, slug, "uuid-1", "Ben", "Benjamin")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_rename_updates_standings(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    _put(client, slug, "uuid-1", "Ben")
    _rename(client, slug, "uuid-1", "Ben", "Benjamin")
    standings = client.get(f"/races/{slug}/standings").json()["participants"]
    names = [p["name"] for p in standings]
    assert "Benjamin" in names
    assert "Ben" not in names


def test_rename_forbidden_wrong_id(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    resp = _rename(client, slug, "uuid-WRONG", "Ben", "Benjamin")
    assert resp.status_code == 403


def test_rename_conflict_name_taken(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    client.post(f"/races/{slug}/register", json={"id": "uuid-1", "name": "Ben"})
    client.post(f"/races/{slug}/register", json={"id": "uuid-2", "name": "Benjamin"})
    resp = _rename(client, slug, "uuid-1", "Ben", "Benjamin")
    assert resp.status_code == 409


def test_rename_unknown_race_returns_404(client):
    resp = _rename(client, "nonexistent", "uuid-1", "Ben", "Benjamin")
    assert resp.status_code == 404
```

- [ ] **Step 2: Run tests — expect failures**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
source .venv/bin/activate
pytest tests/test_routes.py -v 2>&1 | grep -E "(PASSED|FAILED|ERROR)" | head -20
```

Expected: many failures — missing routes, wrong PUT signature.

- [ ] **Step 3: Write the updated `server/app/routes.py`**

```python
# server/app/routes.py
from fastapi import APIRouter, Depends, HTTPException
from redis import Redis

from .dependencies import get_redis
from .models import (
    CreateRaceRequest,
    CreateRaceResponse,
    Participant,
    ParticipantPayload,
    RegisterRequest,
    RenameRequest,
    StandingsResponse,
)
from .store import (
    check_and_reset_epoch,
    create_race,
    get_participants,
    get_race_name,
    register_name,
    rename_participant,
    sorted_standings,
    upsert_participant,
)

router = APIRouter()


@router.post("/races", status_code=201, response_model=CreateRaceResponse)
def post_create_race(body: CreateRaceRequest, r: Redis = Depends(get_redis)):
    slug = create_race(r, body.name)
    return CreateRaceResponse(slug=slug, name=body.name)


@router.post("/races/{slug}/register")
def post_register(slug: str, body: RegisterRequest, r: Redis = Depends(get_redis)):
    if not get_race_name(r, slug):
        raise HTTPException(status_code=404, detail="Race not found")
    result = register_name(r, slug, body.name, body.id)
    if result == "conflict":
        raise HTTPException(status_code=409, detail="Name taken")
    return {"status": "ok"}


@router.put("/races/{slug}/participant")
def put_participant(slug: str, body: ParticipantPayload, r: Redis = Depends(get_redis)):
    payload = {
        "id": body.id,
        "name": body.name,
        "cost_used_cents": str(body.cost_used_cents),
        "cost_limit_cents": str(body.cost_limit_cents),
        "updated_at": body.updated_at,
    }
    result = upsert_participant(r, slug, payload)
    if result == "not_found":
        raise HTTPException(status_code=404, detail="Race not found")
    if result == "forbidden":
        raise HTTPException(status_code=403, detail="ID does not match name owner")
    return {"status": "ok"}


@router.post("/races/{slug}/participant/rename")
def post_rename(slug: str, body: RenameRequest, r: Redis = Depends(get_redis)):
    result = rename_participant(r, slug, body.old_name, body.new_name, body.id)
    if result == "not_found":
        raise HTTPException(status_code=404, detail="Race not found")
    if result == "forbidden":
        raise HTTPException(status_code=403, detail="ID does not match name owner")
    if result == "conflict":
        raise HTTPException(status_code=409, detail="Name taken")
    return {"status": "ok"}


@router.get("/races/{slug}/standings", response_model=StandingsResponse)
def get_race_standings(slug: str, r: Redis = Depends(get_redis)):
    name = get_race_name(r, slug)
    if name is None:
        raise HTTPException(status_code=404, detail="Race not found")
    check_and_reset_epoch(r, slug)
    raw_participants = sorted_standings(get_participants(r, slug))
    return StandingsResponse(
        race_slug=slug,
        name=name,
        participants=[
            Participant(
                name=p["name"],
                cost_used_cents=int(p["cost_used_cents"]),
                cost_limit_cents=int(p["cost_limit_cents"]),
                updated_at=p["updated_at"],
            )
            for p in raw_participants
        ],
    )
```

- [ ] **Step 4: Run all tests — expect pass**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
source .venv/bin/activate
pytest -v
```

Expected: all tests pass (store + routes).

- [ ] **Step 5: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add server/app/routes.py server/tests/test_routes.py
git commit -m "feat: Add register + rename routes; validate ownership on PUT"
```

---

## Task 4: Swift — participantID in RaceSettings

**Files:**
- Modify: `Claude Usage/Shared/Storage/RaceSettings.swift`
- Modify: `Claude UsageTests/RaceSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

In `Claude UsageTests/RaceSettingsTests.swift`, add this test inside `RaceSettingsTests`:

```swift
func testParticipantID_generatedOnce() {
    // Clear stored ID
    UserDefaults.standard.removeObject(forKey: "raceParticipantID")

    let id1 = RaceSettings.shared.participantID
    let id2 = RaceSettings.shared.participantID

    // Must be a valid UUID string
    XCTAssertNotNil(UUID(uuidString: id1))
    // Must be stable across reads
    XCTAssertEqual(id1, id2)
}
```

Also add `"raceParticipantID"` to the `setUp` cleanup list:

```swift
override func setUp() {
    super.setUp()
    let keys = ["raceEnabled", "raceURL", "raceParticipantName",
                "racePushInterval", "racePollInterval", "raceParticipantID"]
    keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceSettingsTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|FAILED|PASSED|participantID)" | head -10
```

Expected: error — `participantID` not found on `RaceSettings`.

- [ ] **Step 3: Add `participantID` to `RaceSettings.swift`**

In `Claude Usage/Shared/Storage/RaceSettings.swift`, add a new `Keys` entry and computed property. Add after the `Keys` enum:

```swift
private enum Keys {
    static let raceEnabled       = "raceEnabled"
    static let raceURL           = "raceURL"
    static let participantName   = "raceParticipantName"
    static let pushInterval      = "racePushInterval"
    static let pollInterval      = "racePollInterval"
    static let participantID     = "raceParticipantID"  // ← add this
}
```

Then add the property after `pollInterval`:

```swift
// MARK: - Participant Identity (private UUID, generated once, never changes)

var participantID: String {
    let stored = defaults.string(forKey: Keys.participantID) ?? ""
    if !stored.isEmpty { return stored }
    let newID = UUID().uuidString
    defaults.set(newID, forKey: Keys.participantID)
    return newID
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
xcodebuild test \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceSettingsTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED|error:)" | tail -10
```

Expected: `Test Suite 'RaceSettingsTests' passed`

- [ ] **Step 5: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add "Claude Usage/Shared/Storage/RaceSettings.swift" \
        "Claude UsageTests/RaceSettingsTests.swift"
git commit -m "feat: Add participantID to RaceSettings (persistent local UUID)"
```

---

## Task 5: Swift — RaceService Identity

**Files:**
- Modify: `Claude Usage/Shared/Services/RaceService.swift`

Read the file in full before editing. Add `register()`, update `push()` to include `id`, handle 403 on push, call `register()` from `start()`.

- [ ] **Step 1: Read the current file**

Read `Claude Usage/Shared/Services/RaceService.swift` to understand current structure before editing.

- [ ] **Step 2: Add `register()` function**

Add this method to `RaceService`, after `refresh()`:

```swift
// MARK: - Registration

func register() async {
    guard let urlString = RaceSettings.shared.raceURL,
          let baseURL = URL(string: urlString) else { return }

    let payload: [String: Any] = [
        "id": RaceSettings.shared.participantID,
        "name": RaceSettings.shared.participantName,
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

    let endpoint = baseURL.appendingPathComponent("register")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 10

    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 409 {
            lastError = "Name taken — choose a different name in Settings"
        } else if http.statusCode != 200 {
            lastError = "Registration failed: HTTP \(http.statusCode)"
        }
        _ = data  // response body not needed
    } catch {
        // Registration failure is non-fatal — will retry on next start()
    }
}
```

- [ ] **Step 3: Update `start()` to call `register()`**

In the `start()` method, add `Task { await register() }` after the existing `Task { await push() }` and `Task { await poll() }`:

```swift
func start() {
    guard RaceSettings.shared.raceEnabled,
          RaceSettings.shared.raceURL != nil else { return }
    schedulePushTimer()
    schedulePollTimer()
    Task { await push() }
    Task { await poll() }
    Task { await register() }   // ← add this line
}
```

- [ ] **Step 4: Update `push()` to include `id` and handle 403**

Find the `payload` dict in `push()` and add the `id` field:

```swift
let payload: [String: Any] = [
    "id": RaceSettings.shared.participantID,   // ← add this
    "name": RaceSettings.shared.participantName,
    "cost_used_cents": usedCents,
    "cost_limit_cents": limitCents,
    "updated_at": Self.iso8601Formatter.string(from: Date())
]
```

Update the error handling in `push()` to distinguish 403:

```swift
do {
    let (_, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse {
        if http.statusCode == 403 {
            lastError = "Name conflict — update your name in Settings"
            // Stop the push timer — do not keep hammering a 403
            pushTimer?.invalidate()
            pushTimer = nil
        } else if http.statusCode != 200 {
            lastError = "Push failed: HTTP \(http.statusCode)"
        }
    }
} catch {
    lastError = "Push error: \(error.localizedDescription)"
}
```

- [ ] **Step 5: Build to verify**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add "Claude Usage/Shared/Services/RaceService.swift"
git commit -m "feat: RaceService registers on start, includes id in push, handles 403"
```

---

## Task 6: Swift — HorseRaceSettingsView Rename

**Files:**
- Modify: `Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift`

Read the file in full before editing. When the participant name is submitted, if already registered in a race, call the rename API. Show inline error on 409. Revert field on failure.

- [ ] **Step 1: Read the current file**

Read `Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift` to understand the current `participantName` field and `onChange` handler.

- [ ] **Step 2: Add rename state and logic**

Add two new `@State` properties inside `HorseRaceSettingsView`:

```swift
@State private var nameError: String? = nil
@State private var previousName: String = RaceSettings.shared.participantName
```

- [ ] **Step 3: Update the participant name section**

Replace the `SettingsSectionCard` for "Your Name" with:

```swift
SettingsSectionCard(
    title: "Your Name",
    subtitle: "How you appear on the race track."
) {
    VStack(alignment: .leading, spacing: 6) {
        TextField("e.g. Ben", text: $participantName)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onSubmit {
                saveName()
            }

        if let error = nameError {
            Text(error)
                .font(.system(size: 10))
                .foregroundColor(.red)
        }
    }
}
.onChange(of: participantName) { _, _ in
    nameError = nil  // clear error as user types
}
```

- [ ] **Step 4: Add `saveName()` method**

Add this private method to `HorseRaceSettingsView`:

```swift
private func saveName() {
    let trimmed = participantName.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        participantName = previousName
        return
    }

    let old = previousName
    guard trimmed != old else { return }

    // If a race is configured, call rename API
    guard let urlString = RaceSettings.shared.raceURL,
          let baseURL = URL(string: urlString) else {
        // No race configured — just save locally
        RaceSettings.shared.participantName = trimmed
        previousName = trimmed
        return
    }

    let payload: [String: Any] = [
        "id": RaceSettings.shared.participantID,
        "old_name": old,
        "new_name": trimmed,
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

    var request = URLRequest(url: baseURL.appendingPathComponent("participant/rename"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 10

    Task {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            await MainActor.run {
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 200 {
                        RaceSettings.shared.participantName = trimmed
                        previousName = trimmed
                        nameError = nil
                    } else if http.statusCode == 409 {
                        nameError = "Name already taken"
                        participantName = old  // revert
                    } else {
                        // Non-fatal — save locally and retry on next push
                        RaceSettings.shared.participantName = trimmed
                        previousName = trimmed
                    }
                }
            }
        } catch {
            // Network error — save locally, will register on next start
            await MainActor.run {
                RaceSettings.shared.participantName = trimmed
                previousName = trimmed
            }
        }
    }
}
```

Also remove the existing `onChange(of: participantName)` that directly calls `RaceSettings.shared.participantName = newValue` — name saves now go through `saveName()` on submit only.

- [ ] **Step 5: Build to verify**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add "Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift"
git commit -m "feat: Rename API call on name change, inline 409 error in Settings"
```
