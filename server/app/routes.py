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
