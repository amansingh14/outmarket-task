import os
import subprocess
import sys
from pathlib import Path

import pytest
from sqlalchemy import create_engine, inspect

from app.dbadmin import provision

BACKEND = Path(__file__).resolve().parents[1]


def _alembic(db_url: str, *args: str) -> None:
    env = {**os.environ, "DATABASE_URL": db_url}
    subprocess.run([sys.executable, "-m", "alembic", *args], cwd=BACKEND, env=env, check=True, capture_output=True)


def test_upgrade_creates_schema_and_downgrade_removes_it(tmp_path):
    url = f"sqlite:///{tmp_path / 'm.db'}"
    _alembic(url, "upgrade", "head")
    insp = inspect(create_engine(url))
    assert {c["name"] for c in insp.get_columns("ideas")} == {"id", "content", "created_at"}
    assert "ix_ideas_created_at" in {i["name"] for i in insp.get_indexes("ideas")}
    _alembic(url, "downgrade", "base")
    assert not inspect(create_engine(url)).has_table("ideas")


def test_upgrade_adopts_table_created_before_migrations(tmp_path):
    url = f"sqlite:///{tmp_path / 'legacy.db'}"
    from app.db import Base

    Base.metadata.create_all(create_engine(url))  # what the app used to do on startup
    _alembic(url, "upgrade", "head")  # must not fail on the existing table


@pytest.mark.parametrize("db,user", [("ideas;drop", "app"), ("ideas", "App-User"), ("1ideas", "app")])
def test_provision_rejects_unsafe_identifiers(db, user):
    with pytest.raises(ValueError, match="not a valid identifier"):
        provision("postgresql://unused", db, user, "pw", create_database=True)


@pytest.mark.skipif(not os.getenv("PG_ADMIN_URL"), reason="set PG_ADMIN_URL to a Postgres admin URL to run")
def test_provision_against_real_postgres():
    import psycopg

    admin = os.environ["PG_ADMIN_URL"]
    first = provision(admin, "ideas_t_dev", "ideas_t_dev_app", "s3cret-one", create_database=True)
    assert any("created database" in s for s in first)
    again = provision(admin, "ideas_t_dev", "ideas_t_dev_app", "s3cret-two", create_database=True)  # idempotent
    assert not any("created" in s for s in again[1:])
    base = admin.rsplit("/", 1)[0]
    user_url = base.replace(base.split("//", 1)[1].split("@")[0], "ideas_t_dev_app:s3cret-two")
    with psycopg.connect(f"{user_url}/ideas_t_dev") as conn:  # owner can create tables (public schema)
        conn.execute("CREATE TABLE IF NOT EXISTS t (id int)")
