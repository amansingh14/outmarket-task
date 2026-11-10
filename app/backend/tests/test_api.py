import os

os.environ["DATABASE_URL"] = "sqlite:///./test.db"

import pytest
from fastapi.testclient import TestClient

from app.db import Base, engine
from app.main import app


@pytest.fixture()
def client():
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)  # migrations own the schema in real deployments (test_migrations.py)
    with TestClient(app) as c:
        yield c
    Base.metadata.drop_all(engine)


def test_empty_list(client):
    r = client.get("/api/ideas")
    assert r.status_code == 200
    assert r.json() == []


def test_create_and_list(client):
    r = client.post("/api/ideas", json={"content": "  My new idea  "})
    assert r.status_code == 201
    body = r.json()
    assert body["content"] == "My new idea"
    assert {"id", "content", "created_at"} <= body.keys()

    client.post("/api/ideas", json={"content": "Second"})
    ideas = client.get("/api/ideas").json()
    assert [i["content"] for i in ideas] == ["Second", "My new idea"]


@pytest.mark.parametrize("payload", [{}, {"content": ""}, {"content": "   "}, {"content": "x" * 501}])
def test_validation(client, payload):
    assert client.post("/api/ideas", json=payload).status_code == 422


def test_health_ready_metrics(client):
    assert client.get("/api/health").json()["status"] == "ok"
    assert client.get("/api/ready").status_code == 200
    client.get("/api/ideas")
    assert "http_requests_total" in client.get("/metrics").text
