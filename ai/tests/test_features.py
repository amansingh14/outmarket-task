import json

import pytest

from devops_ai import chatops, health, plan_review, scaffold, stack_profile
from devops_ai.pricing import estimate_monthly_cost
from devops_ai.redact import redact


@pytest.fixture(autouse=True)
def offline(monkeypatch):
    monkeypatch.setenv("DEVOPS_AI_OFFLINE", "1")


# ------------------------------------------------------------- env profile
def test_offline_cost_sensitive_staging():
    p, source, _ = stack_profile.propose("cost-sensitive staging under $120/month", "staging")
    assert source.startswith("offline")
    assert p.tier == "staging" and p.node_size == "small" and p.spot_nodes
    assert p.monthly_budget_usd == 120


def test_offline_production_is_ha():
    p, _, _ = stack_profile.propose("high-availability production", "production")
    assert p.db_high_availability and p.deletion_protection and not p.zonal_control_plane


def test_guardrails_override_unsafe_production():
    unsafe = stack_profile.StackProfile(
        stack="production", tier="production", node_size="small", node_min=1, node_desired=1,
        node_max=1, spot_nodes=True, db_size="small", db_storage_gb=20, db_high_availability=False,
        deletion_protection=False, zonal_control_plane=True, backend_replicas=1, frontend_replicas=1,
        autoscaling=False, hpa_max_replicas=1, hpa_cpu_target=70, log_level="INFO", rationale="x",
    )
    fixed, notes = stack_profile.apply_guardrails(unsafe)
    assert fixed.deletion_protection and fixed.db_high_availability and not fixed.spot_nodes
    assert fixed.node_min >= 2 and fixed.node_max >= fixed.node_desired >= fixed.node_min
    assert fixed.backend_replicas >= 2 and len(notes) >= 5


def test_render_writes_tfvars_and_values(tmp_path):
    p, _, _ = stack_profile.propose("staging", "staging")
    tf, values = stack_profile.render(p, "gcp", tmp_path)
    data = json.loads(tf.read_text())
    assert data["stack"] == "staging" and data["node_size"] == "small"
    assert "backend" in values.read_text()


def test_cost_model_orders_tiers():
    cheap, _, _ = stack_profile.propose("cost-sensitive staging", "staging")
    prod, _, _ = stack_profile.propose("production", "production")
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


def test_offline_verdict_never_healthy_when_a_hard_gate_failed():
    sig = health.Signals(
        "ns", "rel", [], ["2026-11-09T16:30:00Z  BackOff  idea-board-db-provision-x  Back-off pulling image"],
        {}, [], {}, "", ["helm upgrade failed: job idea-board-db-provision failed: DeadlineExceeded"])
    v = health._offline_verdict(sig)
    assert v.verdict == "unhealthy" and v.recommended_action == "rollback"
    assert "image pull" in v.suspected_cause
    assert any(e.startswith("event:") for e in v.evidence)


def _cluster_plan(rtype, attr, before, after, actions=("update",)):
    return json.dumps({"resource_changes": [{"address": "module.cluster.x", "type": rtype, "change": {
        "actions": list(actions), "before": {attr: before}, "after": {attr: after}}}]})


def test_version_skip_gate():
    from devops_ai import plan_review as pr
    assert pr.version_skips(_cluster_plan("aws_eks_cluster", "version", "1.31", "1.32")) == []
    assert "next: 1.32" in pr.version_skips(_cluster_plan("aws_eks_cluster", "version", "1.31", "1.34"))[0]
    assert pr.version_skips(_cluster_plan("aws_eks_cluster", "version", "1.33", "1.32"))  # downgrade
    assert pr.version_skips(_cluster_plan("google_container_cluster", "min_master_version", "1.30.5-gke.1", "1.33"))
    # a brand-new cluster may start at any version
    assert pr.version_skips(_cluster_plan("aws_eks_cluster", "version", None, "1.34", ("create",))) == []


def test_apply_matrix_keeps_only_clouds_with_changes(tmp_path):
    from devops_ai import plan_review as pr
    noop = {"resource_changes": [{"address": "a", "type": "t", "change": {"actions": ["no-op"]}}]}
    upd = {"resource_changes": [{"address": "b", "type": "t", "change": {"actions": ["update"]}}]}
    out_only = {"resource_changes": [], "output_changes": {"url": {"actions": ["update"]}}}
    (tmp_path / "aws.plan.json").write_text(json.dumps(noop))
    (tmp_path / "gcp.plan.json").write_text(json.dumps(upd))
    m = {"include": [{"cloud": "aws", "stack": "nonprod"}, {"cloud": "gcp", "stack": "nonprod"},
                     {"cloud": "azure", "stack": "nonprod"}]}  # azure: no plan file (not configured)
    assert [e["cloud"] for e in pr.apply_matrix(m, str(tmp_path))["include"]] == ["gcp"]
    assert pr.has_changes(json.dumps(out_only)) and not pr.has_changes(json.dumps(noop))
