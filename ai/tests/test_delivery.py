import copy
from pathlib import Path

import pytest
import yaml

from devops_ai import delivery

REPO = Path(__file__).resolve().parents[2]
CONFIG = REPO / "config" / "deployments.yaml"


@pytest.fixture(scope="module")
def d():
    return delivery.load(CONFIG)


def test_promotion_path(d):
    assert d.path() == ["development", "staging", "qa", "preprod", "production"]


@pytest.mark.parametrize("head,base", [
    ("feature/login", "development"),
    ("fix/typo", "development"),
    ("dependabot/pip/fastapi-1.0", "development"),
    ("development", "staging"),
    ("staging", "qa"),
    ("qa", "preprod"),
    ("preprod", "production"),
    ("hotfix/db-timeout", "production"),
    ("production", "development"),  # back-merge
    ("anything", "main"),  # unmanaged base branch
])
def test_allowed_prs(d, head, base):
    ok, reason = d.check_promotion(base, head)
    assert ok, reason


@pytest.mark.parametrize("head,base,needle", [
    ("feature/login", "staging", "only merge into `development`"),
    ("feature/login", "production", "only merge into `development`"),
    ("development", "production", "only merge into `staging`"),  # skipping environments
    ("staging", "preprod", "only merge into `qa`"),
    ("hotfix/x", "development", "only merge into `production`"),
    ("my-branch", "development", "no promotion rule"),
    ("qa", "staging", "only merge into `preprod`"),  # backwards
])
def test_blocked_prs(d, head, base, needle):
    ok, reason = d.check_promotion(base, head)
    assert not ok and needle in reason


def test_deploy_matrix_follows_cloud_placement(d):
    assert [m["cloud"] for m in d.deploy_matrix("development")["include"]] == ["aws"]
    prod = d.deploy_matrix("production")["include"]
    assert [m["cloud"] for m in prod] == ["aws", "gcp"]
    assert all(m["namespace"] == "idea-board" and m["database"] == "ideas" for m in prod)


def test_stacks(d):
    assert d.stack_for_branch("development") == "nonprod"
    assert d.stack_for_branch("staging") is None  # staging rides on the nonprod stack
    assert d.stack_for_branch("production") == "production"
    assert d.stack_clouds("nonprod") == ["aws"]
    assert d.stack_clouds("preprod") == ["aws", "gcp"]
    assert {e.name for e in d.stack_environments("nonprod")} == {"development", "staging", "qa"}


def test_env_values(d):
    dev = d.env_values("development", REPO)
    assert dev["backend"]["replicas"] == 1 and dev["backend"]["logLevel"] == "DEBUG"
    assert dev["database"] == {"mode": "external", "existingSecret": "idea-board-db",
                               "createDatabase": True, "name": "ideas_development"}
    assert dev["backend"]["autoscaling"]["enabled"] is False
    prod = d.env_values("production", REPO)
    assert prod["database"]["createDatabase"] is False
    assert prod["backend"]["autoscaling"]["enabled"] is True
    assert prod["backend"]["replicas"] >= 2


def _broken(mutate):
    raw = yaml.safe_load(CONFIG.read_text())
    mutate(raw)
    envs = {n: delivery.Environment(name=n, **c) for n, c in raw["environments"].items()}
    return delivery.Delivery(raw["registry"], raw["stacks"], envs, raw["promotion"])


@pytest.mark.parametrize("mutate,needle", [
    (lambda r: r["environments"]["staging"].update(namespace="development"), "share ns"),
    (lambda r: r["environments"]["qa"].update(database="ideas_staging"), "share db"),
    (lambda r: r["environments"]["qa"].update(create_database=False), "create_database must be true"),
    (lambda r: r["environments"]["qa"].update(clouds=["azure"]), "clouds must be"),
    (lambda r: r["environments"]["production"].update(promote_to="development"), "promotion cycle"),
    (lambda r: r["environments"]["qa"].update(database="drop table;"), "invalid database name"),
])
def test_validation_rejects_bad_config(mutate, needle):
    with pytest.raises(ValueError, match=needle):
        delivery.validate(_broken(mutate))


def test_config_is_valid_and_unchanged_by_load():
    raw = yaml.safe_load(CONFIG.read_text())
    before = copy.deepcopy(raw)
    delivery.load(CONFIG)
    assert yaml.safe_load(CONFIG.read_text()) == before
