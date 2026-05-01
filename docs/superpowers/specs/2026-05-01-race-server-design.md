# Race Server — Production Design Spec
_2026-05-01_

## Context

The Claude Usage horse race feature lets team members on a shared Claude enterprise plan race each other to the monthly spend cap. The local macOS app pushes each user's cost burn to a shared remote API and polls standings. The debug server (`debug/debug_race_server.py`) proved the API contract in-memory. This spec covers the production server: Python + FastAPI + Redis, deployed to Railway via Docker.

---

## Goals

- Implement the same API contract as the debug server, plus explicit race creation
- Persist race data across restarts using Redis
- Auto-expire inactive races after 60 days (Redis TTL)
- Deploy to Railway with minimal configuration
- Zero manual secret management — Railway wires Redis automatically

---

## Architecture

```
Client (macOS app)
  │
  ▼
FastAPI (Railway service, $PORT)
  │  POST /races
  │  PUT  /races/{slug}/participant
  │  GET  /races/{slug}/standings
  │  GET  /health
  │
  ▼
Redis (Railway add-on, $REDIS_URL)
```

**File structure:**
```
server/
  app/
    main.py       ← FastAPI app, route registration, lifespan (Redis connection)
    routes.py     ← all four endpoints
    store.py      ← Redis read/write (only file that touches Redis)
    models.py     ← Pydantic request/response models
  Dockerfile
  railway.toml
  requirements.txt
```

`store.py` is the single Redis boundary — routes never call Redis directly.

---

## API

### POST /races

Create a new race. Returns a UUID slug — this is the secret. Share the full URL with teammates.

```
POST /races
Content-Type: application/json

{ "name": "NICE-TEAM" }

→ 201 Created
{
  "slug": "a3f9c2d1-...",
  "name": "NICE-TEAM"
}
```

### PUT /races/{slug}/participant

Upsert a participant's current cost burn. Also refreshes the TTL on both the race meta and participant keys, so active races never expire mid-month.

```
PUT /races/{slug}/participant
Content-Type: application/json

{
  "name": "Ben",
  "cost_used_cents": 42300,
  "cost_limit_cents": 100000,
  "updated_at": "2026-05-01T14:23:00Z"
}

→ 200 OK  { "status": "ok" }
→ 400     malformed payload
→ 404     slug not found
```

### GET /races/{slug}/standings

Returns all participants sorted by `cost_used_cents / cost_limit_cents` descending. Includes race display name so the client can show it in the header instead of the UUID slug.

```
GET /races/{slug}/standings

→ 200 OK
{
  "race_slug": "a3f9c2d1-...",
  "name": "NICE-TEAM",
  "participants": [
    {
      "name": "Alice",
      "cost_used_cents": 61500,
      "cost_limit_cents": 100000,
      "updated_at": "2026-05-01T14:20:00Z"
    }
  ]
}

→ 404  slug not found
```

### GET /health

Railway healthcheck endpoint.

```
→ 200 OK  { "status": "ok" }
```

---

## Redis Schema

Two key types per race. All keys carry a 60-day TTL; PUT refreshes both.

| Key | Type | Fields | TTL |
|-----|------|--------|-----|
| `race:{slug}:meta` | Hash | `name`, `created_at` | 60 days |
| `race:{slug}:p:{name}` | Hash | `name`, `cost_used_cents`, `cost_limit_cents`, `updated_at` | 60 days |

`GET /standings` uses `SCAN` with pattern `race:{slug}:p:*` to find all participants (never `KEYS` — it blocks Redis), reads each hash in a pipeline, sorts client-side by % descending.

**TTL behaviour:** Any PUT on a race refreshes both the participant key and the meta key. A race with zero activity for 60 days auto-expires. There is no manual delete endpoint — not needed for MVP.

---

## Docker

```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ ./app/
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

Port hardcoded to 8080 in image; Railway routes `$PORT` traffic to it.

---

## Railway Config

**`railway.toml`:**
```toml
[build]
builder = "dockerfile"

[deploy]
startCommand = "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}"
healthcheckPath = "/health"
healthcheckTimeout = 10
restartPolicyType = "on_failure"

[[services]]
name = "horse-race-server"

[[plugins]]
name = "redis"
```

**Environment variables (injected automatically by Railway):**
- `$PORT` — public port
- `$REDIS_URL` — Redis connection string (`redis://default:pass@host:6379`)

No manual secret configuration required.

---

## Requirements

```
fastapi>=0.111
uvicorn[standard]>=0.29
redis>=5.0
pydantic>=2.0
```

---

## Swift Client Update

The `GET /standings` response now includes a `name` field alongside `race_slug`. The Swift `RaceStandings` model needs a new optional property:

```swift
struct RaceStandings: Codable {
    let raceSlug: String
    let name: String?          // ← new: human-readable race name
    let participants: [RaceParticipant]
}
```

The race tab header should prefer `name` over `raceSlug` when displaying the race label.

---

## Out of Scope (MVP)

- Race deletion endpoint
- Participant removal
- Admin UI
- Rate limiting
- Authentication beyond slug-as-secret
- Multiple Redis replicas / HA setup
