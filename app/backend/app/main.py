import logging
import time
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from .config import get_settings
from .db import Idea, engine, get_session, wait_for_db

settings = get_settings()
logging.basicConfig(
    level=settings.log_level,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
)
log = logging.getLogger("idea-board")

REQUESTS = Counter(
    "http_requests_total", "HTTP requests", ["method", "route", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency", ["method", "route"]
)


@asynccontextmanager
async def lifespan(_: FastAPI):
    # Survive starting before the database is reachable (compose, first boot in Kubernetes).
    wait_for_db()
    yield


app = FastAPI(title="Idea Board API", version=settings.app_version, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.cors_origins.split(",")],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        path = getattr(route, "path", "unmatched")
        LATENCY.labels(request.method, path).observe(time.perf_counter() - start)
        REQUESTS.labels(request.method, path, str(status)).inc()
        if status >= 500:
            log.error("request failed method=%s path=%s status=%s", request.method, path, status)


class IdeaIn(BaseModel):
    content: str = Field(..., min_length=1)

    @field_validator("content")
    @classmethod
    def _clean(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("content must not be blank")
        if len(v) > settings.max_idea_length:
            raise ValueError(f"content must be at most {settings.max_idea_length} characters")
        return v


class IdeaOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    content: str
    created_at: datetime


@app.get("/api/ideas", response_model=list[IdeaOut])
def list_ideas(session: Session = Depends(get_session)):
    return session.scalars(select(Idea).order_by(Idea.created_at.desc(), Idea.id.desc())).all()


@app.post("/api/ideas", response_model=IdeaOut, status_code=201)
def create_idea(payload: IdeaIn, session: Session = Depends(get_session)):
    idea = Idea(content=payload.content)
    session.add(idea)
    session.commit()
    session.refresh(idea)
    log.info("idea created id=%s", idea.id)
    return idea


@app.get("/api/health")
def health():
    """Liveness: the process is up."""
    return {"status": "ok", "version": settings.app_version}


@app.get("/api/ready")
def ready():
    """Readiness: we can reach the database."""
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception as exc:
        log.error("readiness check failed: %s", exc)
        raise HTTPException(status_code=503, detail="database unavailable") from exc
    return {"status": "ready"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
