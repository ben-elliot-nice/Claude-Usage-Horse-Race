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
