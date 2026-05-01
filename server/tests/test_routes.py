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
