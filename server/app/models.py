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
