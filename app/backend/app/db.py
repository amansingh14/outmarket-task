from collections.abc import Iterator
from datetime import datetime, timezone

from sqlalchemy import DateTime, Integer, String, create_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker

from .config import get_settings


def _normalise_url(url: str) -> str:
    # Accept plain postgres:// URLs (what most managed DBs hand out) and use psycopg v3.
    for prefix in ("postgres://", "postgresql://"):
        if url.startswith(prefix):
            return "postgresql+psycopg://" + url[len(prefix):]
    return url


class Base(DeclarativeBase):
    pass


class Idea(Base):
    __tablename__ = "ideas"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    content: Mapped[str] = mapped_column(String(1000), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        index=True,  # ix_ideas_created_at, created by migration 0001
        default=lambda: datetime.now(timezone.utc),
    )


_url = _normalise_url(get_settings().database_url)
engine = create_engine(
    _url,
    pool_pre_ping=True,
    **({} if _url.startswith("sqlite") else {"pool_size": 5, "max_overflow": 5}),
)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def wait_for_db(attempts: int = 30, delay: float = 2.0) -> None:
    """Block until the database answers. The schema itself is owned by Alembic migrations
    (a Helm hook in Kubernetes, RUN_MIGRATIONS=true in docker compose), never by the app."""
    import logging
    import time

    from sqlalchemy import text

    log = logging.getLogger("idea-board")
    for attempt in range(1, attempts + 1):
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            log.info("database ready (attempt %s)", attempt)
            return
        except Exception as exc:  # noqa: BLE001
            log.warning("database not ready (attempt %s): %s", attempt, exc)
            time.sleep(delay)
    raise RuntimeError("database never became ready")


def get_session() -> Iterator[Session]:
    with SessionLocal() as session:
        yield session
