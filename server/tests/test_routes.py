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
