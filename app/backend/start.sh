#!/bin/sh
# Container entrypoint. In Kubernetes, migrations run once per release in a Helm hook Job;
# docker compose and single-replica preview environments set RUN_MIGRATIONS=true instead.
set -e
if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
  alembic upgrade head
fi
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers
