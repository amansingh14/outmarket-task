import json

import pytest

from devops_ai import chatops, env_profile, health, plan_review, scaffold
from devops_ai.pricing import estimate_monthly_cost
from devops_ai.redact import redact


@pytest.fixture(autouse=True)
def offline(monkeypatch):
    monkeypatch.setenv("DEVOPS_AI_OFFLINE", "1")


# ------------------------------------------------------------- env profile
def test_offline_cost_sensitive_staging():
    p, source, _ = env_profile.propose("cost-sensitive staging under $120/month", "staging")
    assert source.startswith("offline")
    assert p.tier == "staging" and p.node_size == "small" and p.spot_nodes
    assert p.monthly_budget_usd == 120


def test_offline_production_is_ha():
    p, _, _ = env_profile.propose("high-availability production", "production")
    assert p.db_high_availability and p.deletion_protection and not p.zonal_control_plane


def test_guardrails_override_unsafe_production():
    unsafe = env_profile.EnvProfile(
        environment="production", tier="production", node_size="small", node_min=1, node_desired=1,
        node_max=1, spot_nodes=True, db_size="small", db_storage_gb=20, db_high_availability=False,
        deletion_protection=False, zonal_control_plane=True, backend_replicas=1, frontend_replicas=1,
        autoscaling=False, hpa_max_replicas=1, hpa_cpu_target=70, log_level="INFO", rationale="x",
    )
    fixed, notes = env_profile.apply_guardrails(unsafe)
    assert fixed.deletion_protection and fixed.db_high_availability and not fixed.spot_nodes
    assert fixed.node_min >= 2 and fixed.node_max >= fixed.node_desired >= fixed.node_min
    assert fixed.backend_replicas >= 2 and len(notes) >= 5


def test_render_writes_tfvars_and_values(tmp_path):
    p, _, _ = env_profile.propose("staging", "staging")
    tf, values = env_profile.render(p, "gcp", tmp_path)
    data = json.loads(tf.read_text())
    assert data["environment"] == "staging" and data["node_size"] == "small"
    assert "backend" in values.read_text()


def test_cost_model_orders_tiers():
    cheap, _, _ = env_profile.propose("cost-sensitive staging", "staging")
    prod, _, _ = env_profile.propose("production", "production")
    for cloud in ("aws", "gcp"):
        assert estimate_monthly_cost(cheap, cloud)["total"] < estimate_monthly_cost(prod, cloud)["total"]


# ---------------------------------------------------------------- chatops
CTX = chatops.Context(pr_number=7, image_owner="acme", image_tag="sha-123")


def test_offline_deploy_preview_plan_passes_policy():
    p, _ = chatops.plan("/deploy-preview gcp 3 replicas", CTX)
    assert p.intent == "deploy_preview" and p.cloud == "gcp" and p.namespace == "preview-pr-7"
    assert "backend.replicas=3" in p.steps[0].args
    assert chatops.validate(p).allowed


def test_offline_teardown_plan_passes_policy():
    p, _ = chatops.plan("/teardown-preview", CTX)
    assert p.intent == "teardown_preview" and chatops.validate(p).allowed


def test_malicious_ai_plan_is_blocked():
    p = chatops.DeployPlan(intent="deploy_preview", cloud="aws", namespace="production", summary="", risk="low",
                           steps=[chatops.Step(description="x", tool="kubectl",
                                               args=["delete", "namespace", "production"])])
    v = chatops.validate(p)
    assert not v.allowed


# ------------------------------------------------------------ plan review
def _plan(*changes):
    return json.dumps({"resource_changes": [
        {"address": a, "type": t, "change": {"actions": acts, "before": {}, "after": {}}} for a, t, acts in changes
    ]})


def test_plan_review_flags_database_replacement():
    pj = _plan(("module.database.aws_db_instance.this", "aws_db_instance", ["delete", "create"]),
               ("module.x.aws_iam_role.r", "aws_iam_role", ["create"]))
    destroy = plan_review.destructive_stateful(plan_review.parse(pj))
    assert [c.address for c in destroy] == ["module.database.aws_db_instance.this"]
    r, _ = plan_review.review(pj, "aws", "staging")
    assert r.risk == "critical"
    assert "Hard gate" in plan_review.to_markdown(pj, r, "offline", "aws", "staging")


def test_plan_review_safe_plan():
    pj = _plan(("aws_iam_role.r", "aws_iam_role", ["update"]), ("x.y", "aws_vpc", ["no-op"]))
    assert plan_review.destructive_stateful(plan_review.parse(pj)) == []


# ----------------------------------------------------------------- health
def test_status_counts_ignore_probe_routes():
    raw = "\n".join([
        'http_requests_total{method="GET",route="/api/ready",status="503"} 4.0',
        'http_requests_total{method="GET",route="/api/ideas",status="200"} 10.0',
        'http_requests_total{method="POST",route="/api/ideas",status="500"} 2.0',
    ])
    assert health.parse_status_counts(raw) == {"2xx": 10.0, "5xx": 2.0}


def _sig(hard=None, restarts=0):
    return health.Signals("ns", "rel", [{"name": "p", "component": "backend", "restarts": restarts}], [],
                          {"p": "INFO ok"}, [], {}, "", hard or [])


def test_hard_gate_forces_rollback_even_if_ai_offline():
    sig = _sig(hard=["pod x is CrashLoopBackOff"])
    v, _ = health.judge(sig)
    assert health.decide(sig, v, 0.7).rollback


def test_low_confidence_ai_does_not_roll_back():
    sig = _sig()
    v = health.HealthVerdict(verdict="unhealthy", confidence=0.4, summary="", evidence=[], suspected_cause="",
                             recommended_action="rollback")
    assert not health.decide(sig, v, 0.7).rollback
    v.confidence = 0.9
    assert health.decide(sig, v, 0.7).rollback


# --------------------------------------------------------------- scaffold
def test_scaffold_offline_renders_and_respects_privacy(tmp_path):
    spec = scaffold.ServiceSpec(name="notifier", description="sends emails", image="ghcr.io/acme/notifier",
                                port=9000, public=False, language="go")
    bp, _, _ = scaffold.design(spec)
    assert bp.service_type == "ClusterIP"
    path = scaffold.render(spec, bp, tmp_path)
    assert "containerPort: 9000" in path.read_text()


def test_scaffold_guardrails():
    spec = scaffold.ServiceSpec(name="svc-a", description="", image="x/y", port=80, public=False)
    bp = scaffold._offline(spec).model_copy(update={
        "service_type": "LoadBalancer", "cpu_limit_m": 10, "cpu_request_m": 100,
        "extra_env": [scaffold.EnvVar(name="DB_PASSWORD", value="hunter2")]})
    fixed, notes = scaffold.guardrails(spec, bp)
    assert fixed.service_type == "ClusterIP" and fixed.cpu_limit_m == 100 and not fixed.extra_env
    assert len(notes) == 3


# ----------------------------------------------------------------- redact
def test_redact():
    s = redact("conn postgresql+psycopg://ideas:s3cr3t@db:5432/x password=abc Authorization: Bearer xyz.abc")
    assert "s3cr3t" not in s and "abc Auth" not in s and "xyz.abc" not in s
    assert "ideas:***@db" in s
