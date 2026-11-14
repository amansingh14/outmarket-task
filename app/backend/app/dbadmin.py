"""Database provisioning, run by the Helm pre-install/pre-upgrade hook with *admin* credentials.

    python -m app.dbadmin provision

Gives each environment its own least-privilege login, so the application never sees the master
credentials and development cannot read QA's data on the shared non-prod instance:

  1. create role <APP_USER> (LOGIN) if missing, and set its password from a SCRAM verifier that
     is computed client-side, so the plaintext never reaches the server or its statement log
     (Cloud SQL runs with log_statement=ddl)
  2. create database <DB_NAME> if missing and CREATE_DATABASE=true (shared instance)
  3. make <APP_USER> the database owner (PostgreSQL 15+: the owner controls the public schema,
     so migrations can create tables) and revoke CONNECT from PUBLIC (other environments' roles)

Idempotent; safe on every deploy. Works on RDS and Cloud SQL, where the admin is not a superuser.
Env: ADMIN_DATABASE_URL, DB_NAME, APP_USER, APP_PASSWORD, CREATE_DATABASE.
"""

from __future__ import annotations

import os
import re
import sys

import psycopg
from psycopg import sql

IDENT = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")


def _require(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        sys.exit(f"dbadmin: {name} is required")
    return value


def provision(admin_url: str, db_name: str, app_user: str, app_password: str, create_database: bool) -> list[str]:
    for label, ident in (("DB_NAME", db_name), ("APP_USER", app_user)):
        if not IDENT.match(ident):
            raise ValueError(f"{label} {ident!r} is not a valid identifier")
    done: list[str] = []
    with psycopg.connect(admin_url, autocommit=True) as conn:  # CREATE DATABASE can't run in a transaction
        verifier = conn.pgconn.encrypt_password(app_password.encode(), app_user.encode(), b"scram-sha-256").decode()
        role = sql.Identifier(app_user)

        if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (app_user,)).fetchone():
            conn.execute(sql.SQL("CREATE ROLE {} LOGIN").format(role))
            done.append(f"created role {app_user}")
        conn.execute(sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(role, sql.Literal(verifier)))
        done.append(f"set password for {app_user} (SCRAM verifier)")

        exists = conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (db_name,)).fetchone()
        if not exists:
            if not create_database:
                raise RuntimeError(f"database {db_name} does not exist and CREATE_DATABASE is false")
            conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(db_name)))
            done.append(f"created database {db_name}")

        # RDS / Cloud SQL admins are not superusers: they must be members of a role to give it ownership.
        conn.execute(sql.SQL("GRANT {} TO CURRENT_USER").format(role))
        conn.execute(sql.SQL("ALTER DATABASE {} OWNER TO {}").format(sql.Identifier(db_name), role))
        conn.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM PUBLIC").format(sql.Identifier(db_name)))
        done.append(f"{app_user} owns {db_name}; PUBLIC has no access")
    return done


def main() -> None:
    if sys.argv[1:] != ["provision"]:
        sys.exit("usage: python -m app.dbadmin provision")
    steps = provision(
        admin_url=_require("ADMIN_DATABASE_URL"),
        db_name=_require("DB_NAME"),
        app_user=_require("APP_USER"),
        app_password=_require("APP_PASSWORD"),
        create_database=os.environ.get("CREATE_DATABASE", "false").lower() == "true",
    )
    for s in steps:
        print(f"dbadmin: {s}")


if __name__ == "__main__":
    main()
