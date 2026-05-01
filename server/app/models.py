# server/app/models.py
from pydantic import BaseModel, field_validator


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
