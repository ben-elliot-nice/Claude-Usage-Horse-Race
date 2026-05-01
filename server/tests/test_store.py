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
    r.hset(f"race:{slug}:p:Ben", mapping={
        "name": "Ben", "cost_used_cents": "100",
        "cost_limit_cents": "1000", "updated_at": "t",
    })
    check_and_reset_epoch(r, slug)
    assert not r.exists(f"race:{slug}:p:Ben")


def test_epoch_preserves_names_hash(r):
    slug = create_race(r, "TEST")
    r.hset(f"race:{slug}:names", "Ben", "uuid-1")
    check_and_reset_epoch(r, slug)
    assert r.hget(f"race:{slug}:names", "Ben").decode() == "uuid-1"


def test_epoch_noop_when_sentinel_exists(r):
    slug = create_race(r, "TEST")
    check_and_reset_epoch(r, slug)
    r.hset(f"race:{slug}:p:Ben", mapping={"name": "Ben"})
    check_and_reset_epoch(r, slug)
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
