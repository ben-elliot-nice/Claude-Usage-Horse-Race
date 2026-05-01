# Race Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a production FastAPI + Redis server for the horse race feature and deploy it to Railway via Docker.

**Architecture:** A FastAPI app in `server/` exposes three endpoints (create race, upsert participant, get standings). `store.py` is the sole Redis boundary. `dependencies.py` holds the injectable Redis client to avoid circular imports. Tests use `fakeredis` — no live Redis required.

**Tech Stack:** Python 3.13, FastAPI, Redis (redis-py), Pydantic v2, fakeredis + pytest for tests, Docker, Railway.

---

## Worktree / Working Directory

All server files live under `server/` in the repo root:
```
/Users/Ben.Elliot/repos/claude-usage-horse-race/server/
```

Swift changes are in the existing `Claude Usage/` directory.

## Run Tests

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
pip install -r requirements-dev.txt
pytest -v
```

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `server/requirements.txt` | Create | Runtime dependencies |
| `server/requirements-dev.txt` | Create | Test dependencies (fakeredis, pytest, httpx) |
| `server/Dockerfile` | Create | Container image |
| `server/railway.toml` | Create | Railway deployment config |
| `server/app/__init__.py` | Create | Empty package marker |
| `server/app/models.py` | Create | Pydantic request/response types |
| `server/app/dependencies.py` | Create | Injectable Redis client (avoids circular imports) |
| `server/app/store.py` | Create | All Redis operations |
| `server/app/routes.py` | Create | HTTP route handlers |
| `server/app/main.py` | Create | FastAPI app, lifespan, health endpoint |
| `server/tests/__init__.py` | Create | Empty package marker |
| `server/tests/test_store.py` | Create | Unit tests for store functions using fakeredis |
| `server/tests/test_routes.py` | Create | Integration tests using TestClient + fakeredis |
| `Claude Usage/Shared/Models/RaceParticipant.swift` | Modify | Add `name: String?` to `RaceStandings` |
| `Claude Usage/MenuBar/RaceTabView.swift` | Modify | Prefer `standings.name` over slug in header |

---

## Task 1: Project Scaffold

**Files:**
- Create: `server/requirements.txt`
- Create: `server/requirements-dev.txt`
- Create: `server/Dockerfile`
- Create: `server/railway.toml`
- Create: `server/app/__init__.py`
- Create: `server/tests/__init__.py`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p /Users/Ben.Elliot/repos/claude-usage-horse-race/server/app
mkdir -p /Users/Ben.Elliot/repos/claude-usage-horse-race/server/tests
```

- [ ] **Step 2: Write `server/requirements.txt`**

```
fastapi>=0.111
uvicorn[standard]>=0.29
redis>=5.0
pydantic>=2.0
```

- [ ] **Step 3: Write `server/requirements-dev.txt`**

```
-r requirements.txt
fakeredis>=2.23
pytest>=8.0
httpx>=0.27
```

- [ ] **Step 4: Write `server/Dockerfile`**

```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ ./app/
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 5: Write `server/railway.toml`**

```toml
[build]
builder = "dockerfile"

[deploy]
startCommand = "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}"
healthcheckPath = "/health"
healthcheckTimeout = 10
restartPolicyType = "on_failure"
```

Note: Add the Redis service via the Railway dashboard (Services → New → Database → Redis) and link it to this service. Railway will inject `$REDIS_URL` automatically.

- [ ] **Step 6: Create empty package markers**

```bash
touch /Users/Ben.Elliot/repos/claude-usage-horse-race/server/app/__init__.py
touch /Users/Ben.Elliot/repos/claude-usage-horse-race/server/tests/__init__.py
```

- [ ] **Step 7: Install dev dependencies**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
pip install -r requirements-dev.txt
```

Expected: packages install without error.

- [ ] **Step 8: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add server/
git commit -m "feat: Scaffold race server project (FastAPI + Redis + Railway)"
```

---

## Task 2: Pydantic Models

**Files:**
- Create: `server/app/models.py`

No separate test file — models are exercised by route tests in Task 5. Pydantic validation is tested implicitly (invalid payloads return 422).

- [ ] **Step 1: Write `server/app/models.py`**

```python
# server/app/models.py
from pydantic import BaseModel


class CreateRaceRequest(BaseModel):
    name: str


class CreateRaceResponse(BaseModel):
    slug: str
    name: str


class ParticipantPayload(BaseModel):
    name: str
    cost_used_cents: int
    cost_limit_cents: int
    updated_at: str  # ISO 8601 string — stored verbatim, validated client-side


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

- [ ] **Step 2: Verify import works**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
python -c "from app.models import CreateRaceRequest, StandingsResponse; print('OK')"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add server/app/models.py
git commit -m "feat: Add Pydantic models for race server API"
```

---

## Task 3: Redis Dependency

**Files:**
- Create: `server/app/dependencies.py`

- [ ] **Step 1: Write `server/app/dependencies.py`**

```python
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
```

- [ ] **Step 2: Verify import**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
python -c "from app.dependencies import get_redis, init_redis, close_redis; print('OK')"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add server/app/dependencies.py
git commit -m "feat: Add injectable Redis dependency"
```

---

## Task 4: Redis Store

**Files:**
- Create: `server/app/store.py`
- Create: `server/tests/test_store.py`

- [ ] **Step 1: Write the failing tests**

```python
# server/tests/test_store.py
import fakeredis
import pytest
from app.store import (
    TTL,
    create_race,
    get_race_name,
    get_participants,
    sorted_standings,
    upsert_participant,
)


@pytest.fixture
def r():
    return fakeredis.FakeRedis()


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


def test_upsert_participant_unknown_race_returns_false(r):
    ok = upsert_participant(r, "no-such-race", {
        "name": "Ben",
        "cost_used_cents": "100",
        "cost_limit_cents": "1000",
        "updated_at": "2026-05-01T00:00:00Z",
    })
    assert ok is False


def test_upsert_participant_stores_data(r):
    slug = create_race(r, "TEST")
    ok = upsert_participant(r, slug, {
        "name": "Ben",
        "cost_used_cents": "42300",
        "cost_limit_cents": "100000",
        "updated_at": "2026-05-01T14:00:00Z",
    })
    assert ok is True
    participants = get_participants(r, slug)
    assert len(participants) == 1
    assert participants[0]["name"] == "Ben"
    assert participants[0]["cost_used_cents"] == "42300"


def test_upsert_participant_refreshes_meta_ttl(r):
    slug = create_race(r, "TEST")
    r.expire(f"race:{slug}:meta", 100)
    upsert_participant(r, slug, {
        "name": "Ben",
        "cost_used_cents": "100",
        "cost_limit_cents": "1000",
        "updated_at": "2026-05-01T00:00:00Z",
    })
    ttl = r.ttl(f"race:{slug}:meta")
    assert ttl > 100  # TTL was refreshed to full 60 days


def test_get_participants_empty(r):
    slug = create_race(r, "EMPTY")
    assert get_participants(r, slug) == []


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
```

- [ ] **Step 2: Run tests — expect failure**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
pytest tests/test_store.py -v 2>&1 | head -20
```

Expected: `ModuleNotFoundError: No module named 'app.store'`

- [ ] **Step 3: Write `server/app/store.py`**

```python
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
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
pytest tests/test_store.py -v
```

Expected: `10 passed`

- [ ] **Step 5: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add server/app/store.py server/tests/test_store.py
git commit -m "feat: Add Redis store with SCAN-based standings"
```

---

## Task 5: Routes + FastAPI App

**Files:**
- Create: `server/app/routes.py`
- Create: `server/app/main.py`
- Create: `server/tests/test_routes.py`

- [ ] **Step 1: Write the failing route tests**

```python
# server/tests/test_routes.py
import fakeredis
import pytest
from fastapi.testclient import TestClient

import app.dependencies as deps
from app.main import app


@pytest.fixture(autouse=True)
def fake_redis():
    """Inject fakeredis before each test, clean up after."""
    deps._redis = fakeredis.FakeRedis()
    yield
    deps._redis = None


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


# --- Health ---

def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


# --- POST /races ---

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


# --- PUT /races/{slug}/participant ---

def test_put_participant_returns_200(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    resp = client.put(f"/races/{slug}/participant", json={
        "name": "Ben",
        "cost_used_cents": 42300,
        "cost_limit_cents": 100000,
        "updated_at": "2026-05-01T14:00:00Z",
    })
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_put_participant_unknown_race_returns_404(client):
    resp = client.put("/races/nonexistent/participant", json={
        "name": "Ben",
        "cost_used_cents": 42300,
        "cost_limit_cents": 100000,
        "updated_at": "2026-05-01T14:00:00Z",
    })
    assert resp.status_code == 404


def test_put_participant_missing_field_returns_422(client):
    slug = client.post("/races", json={"name": "TEST"}).json()["slug"]
    resp = client.put(f"/races/{slug}/participant", json={
        "name": "Ben",
        "cost_used_cents": 42300,
        # missing cost_limit_cents and updated_at
    })
    assert resp.status_code == 422


# --- GET /races/{slug}/standings ---

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
    for name, used in [("Carol", 18000), ("Alice", 61500), ("Ben", 42300)]:
        client.put(f"/races/{slug}/participant", json={
            "name": name,
            "cost_used_cents": used,
            "cost_limit_cents": 100000,
            "updated_at": "2026-05-01T14:00:00Z",
        })
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
    client.put(f"/races/{slug}/participant", json={
        "name": "Alice",
        "cost_used_cents": 61500,
        "cost_limit_cents": 100000,
        "updated_at": "2026-05-01T14:20:00Z",
    })
    resp = client.get(f"/races/{slug}/standings")
    p = resp.json()["participants"][0]
    assert p["name"] == "Alice"
    assert p["cost_used_cents"] == 61500
    assert p["cost_limit_cents"] == 100000
    assert p["updated_at"] == "2026-05-01T14:20:00Z"
```

- [ ] **Step 2: Run tests — expect failure**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
pytest tests/test_routes.py -v 2>&1 | head -10
```

Expected: `ModuleNotFoundError: No module named 'app.routes'` or similar.

- [ ] **Step 3: Write `server/app/routes.py`**

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
    StandingsResponse,
)
from .store import create_race, get_participants, get_race_name, sorted_standings, upsert_participant

router = APIRouter()


@router.post("/races", status_code=201, response_model=CreateRaceResponse)
def post_create_race(body: CreateRaceRequest, r: Redis = Depends(get_redis)):
    slug = create_race(r, body.name)
    return CreateRaceResponse(slug=slug, name=body.name)


@router.put("/races/{slug}/participant")
def put_participant(slug: str, body: ParticipantPayload, r: Redis = Depends(get_redis)):
    payload = {
        "name": body.name,
        "cost_used_cents": str(body.cost_used_cents),
        "cost_limit_cents": str(body.cost_limit_cents),
        "updated_at": body.updated_at,
    }
    if not upsert_participant(r, slug, payload):
        raise HTTPException(status_code=404, detail="Race not found")
    return {"status": "ok"}


@router.get("/races/{slug}/standings", response_model=StandingsResponse)
def get_race_standings(slug: str, r: Redis = Depends(get_redis)):
    name = get_race_name(r, slug)
    if name is None:
        raise HTTPException(status_code=404, detail="Race not found")
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

- [ ] **Step 4: Write `server/app/main.py`**

```python
# server/app/main.py
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI

from .dependencies import close_redis, init_redis
from .routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_redis(os.environ.get("REDIS_URL"))
    yield
    close_redis()


app = FastAPI(lifespan=lifespan)
app.include_router(router)


@app.get("/health")
def health():
    return {"status": "ok"}
```

- [ ] **Step 5: Run all tests — expect pass**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
pytest -v
```

Expected: `20 passed` (10 store + 10 route tests)

- [ ] **Step 6: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add server/app/routes.py server/app/main.py server/tests/test_routes.py
git commit -m "feat: Add FastAPI routes and app entrypoint"
```

---

## Task 6: Docker Smoke Test

- [ ] **Step 1: Build the Docker image**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race/server
docker build -t horse-race-server .
```

Expected: `Successfully built ...` — no errors.

- [ ] **Step 2: Run the container and hit /health**

```bash
docker run -d --name race-test -p 8080:8080 \
  -e REDIS_URL="redis://host.docker.internal:6379" \
  horse-race-server

sleep 2
curl -s http://localhost:8080/health
docker rm -f race-test
```

Expected: `{"status":"ok"}`

If no local Redis is running for the container test, just verify the image builds and the health check path is reachable — the health endpoint doesn't need Redis.

- [ ] **Step 3: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git commit --allow-empty -m "chore: Docker build verified locally"
```

---

## Task 7: Swift Client Update

**Files:**
- Modify: `Claude Usage/Shared/Models/RaceParticipant.swift`
- Modify: `Claude Usage/MenuBar/RaceTabView.swift`

The production server's `GET /standings` response now includes a `name` field (the human-readable race name). The Swift client should prefer it over the UUID slug in the header.

- [ ] **Step 1: Add `name: String?` to `RaceStandings`**

In `Claude Usage/Shared/Models/RaceParticipant.swift`, change:

```swift
struct RaceStandings: Codable {
    let raceSlug: String
    let participants: [RaceParticipant]
}
```

to:

```swift
struct RaceStandings: Codable {
    let raceSlug: String
    let name: String?
    let participants: [RaceParticipant]
}
```

- [ ] **Step 2: Update `raceSlugDisplay` in `RaceTabView`**

In `Claude Usage/MenuBar/RaceTabView.swift`, change `raceSlugDisplay`:

```swift
private var raceSlugDisplay: String {
    guard let url = RaceSettings.shared.raceURL,
          let last = URL(string: url)?.lastPathComponent,
          !last.isEmpty else {
        return raceService.standings?.raceSlug ?? "RACE"
    }
    return last
}
```

to:

```swift
private var raceSlugDisplay: String {
    // Prefer the server-provided display name (e.g. "NICE-TEAM") over the UUID slug
    if let name = raceService.standings?.name, !name.isEmpty {
        return name
    }
    guard let url = RaceSettings.shared.raceURL,
          let last = URL(string: url)?.lastPathComponent,
          !last.isEmpty else {
        return raceService.standings?.raceSlug ?? "RACE"
    }
    return last
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
cd /Users/Ben.Elliot/repos/claude-usage-horse-race
git add "Claude Usage/Shared/Models/RaceParticipant.swift" \
        "Claude Usage/MenuBar/RaceTabView.swift"
git commit -m "feat: Show race display name from server in popover header"
```
