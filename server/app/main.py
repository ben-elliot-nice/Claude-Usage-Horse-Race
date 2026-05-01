# server/app/main.py
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI

from .dependencies import close_redis, init_redis
from .routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_redis(os.environ.get("REDIS_URL"))
    yield
    close_redis()


app = FastAPI(lifespan=lifespan)
app.include_router(router)


@app.get("/health")
def health():
    return {"status": "ok"}
