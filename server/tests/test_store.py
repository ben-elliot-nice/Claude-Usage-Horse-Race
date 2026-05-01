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
    p_ttl = r.ttl(f"race:{slug}:p:Ben")
    assert 0 < p_ttl <= TTL  # participant TTL also set


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
    # Zero limit yields 0.0 percentage — Dave still appears, just at the bottom
    assert len(result) == 1
