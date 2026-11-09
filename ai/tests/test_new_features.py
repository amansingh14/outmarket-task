import pytest

from devops_ai import chatops, clouds, evals, health, stack_profile
from devops_ai.pricing import estimate_monthly_cost


@pytest.fixture(autouse=True)
def offline(monkeypatch):
    monkeypatch.setenv("DEVOPS_AI_OFFLINE", "1")


# ------------------------------------------------------------ cloud registry
def test_registry_discovers_plugin_folders():
    assert clouds.names() == ["aws", "gcp"]
    aws = clouds.get("aws")
    assert aws.terraform_root == "infra/terraform/envs/aws"
    assert "AWS_DEPLOY_ROLE_ARN" in aws.github_vars["deploy"]
    with pytest.raises(ValueError, match="unknown cloud 'azure'"):
        clouds.get("azure")


def test_cost_model_reads_plugin_pricing():
    p, _, _ = stack_profile.propose("cheap dev", "nonprod")
    for c in clouds.names():
        cost = estimate_monthly_cost(p, c)
        assert cost["total"] == pytest.approx(sum(v for k, v in cost.items() if k != "total"), abs=0.05)
    # GKE's free tier covers one zonal control plane; EKS always charges for it.
    assert estimate_monthly_cost(p, "gcp")["control_plane"] == 0
    assert estimate_monthly_cost(p, "aws")["control_plane"] == 73


def test_markdown_has_a_cost_column_per_cloud():
    p, source, notes = stack_profile.propose("production", "production")
    md = stack_profile.to_markdown(p, source, notes)
    assert "| | AWS | GCP |" in md


# ------------------------------------------------------------- chatops cloud
def test_plan_for_unknown_cloud_is_blocked():
    ctx = chatops.Context(pr_number=1, image_owner="a", image_tag="t")
    plan, _ = chatops.plan("/deploy-preview", ctx)
    plan.cloud = "azure"
    v = chatops.validate(plan, ctx.available_clouds)
    assert not v.allowed and any("azure" in m for m in v.violations)


def test_context_defaults_come_from_registry():
    ctx = chatops.Context(pr_number=1, image_owner="a", image_tag="t")
    assert ctx.available_clouds == ("aws", "gcp") and ctx.default_cloud == "aws"


# ---------------------------------------------------------- health baseline
def _probe(path, p95):
    return {"url": f"http://lb{path}", "requests": 10, "errors": 0, "error_rate": 0.0, "p50_ms": p95 / 2, "p95_ms": p95}


def test_latency_regression_is_relative_to_baseline():
    base = {"exists": True, "probes": [_probe("/api/ideas", 90)]}
    assert health.latency_regressions(base, [_probe("/api/ideas", 2600)])  # 29x slower and > 1 s
    assert not health.latency_regressions(base, [_probe("/api/ideas", 400)])  # slower, but under 1 s
    slow_before = {"exists": True, "probes": [_probe("/api/ideas", 900)]}
    assert not health.latency_regressions(slow_before, [_probe("/api/ideas", 1500)])  # < 5x
    assert not health.latency_regressions(None, [_probe("/api/ideas", 5000)])  # no baseline: AI decides


@pytest.mark.parametrize("history,expected", [
    ([{"revision": 1, "status": "deployed"}], None),  # first install
    ([{"revision": 1, "status": "superseded"}, {"revision": 2, "status": "deployed"}], 1),
    ([{"revision": 1, "status": "superseded"}, {"revision": 2, "status": "failed"},
      {"revision": 3, "status": "deployed"}], 1),  # skip the failed one, unlike `helm rollback 0`
    ([{"revision": 1, "status": "failed"}, {"revision": 2, "status": "deployed"}], None),
])
def test_last_good_revision(history, expected):
    assert health.last_good_revision(history) == expected


def test_report_shows_before_and_after_latency():
    sig = health.Signals("ns", "rel", [], [], {}, [_probe("/api/ideas", 120)], {}, "", [],
                         baseline={"exists": True, "probes": [_probe("/api/ideas", 80)]})
    v, source = health.judge(sig)
    md = health.to_markdown(sig, v, source, health.decide(sig, v, 0.7), None)
    assert "p95 before deploy" in md and "| 80 ms |" in md


# --------------------------------------------------------------------- evals
def test_offline_eval_subset_passes():
    results = evals.run(offline=True)
    assert results, "no offline cases ran"
    failed = [f"{r.feature}/{r.case}: {r.detail}" for r in results if not r.passed]
    assert not failed, failed
    md = evals.to_markdown(results, offline=True)
    assert "offline fallbacks only" in md
