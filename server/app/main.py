# server/app/main.py
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Depends
from redis import Redis

from .dependencies import close_redis, get_redis, init_redis
from .routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_redis(os.environ.get("REDIS_URL"))
    yield
    close_redis()


app = FastAPI(lifespan=lifespan)
app.include_router(router)


@app.get("/health")
def health(r: Redis = Depends(get_redis)):
    r.ping()
    return {"status": "ok"}
