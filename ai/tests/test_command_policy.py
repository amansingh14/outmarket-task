import pytest

from devops_ai.command_policy import CHART_PATH, check_plan

NS = "preview-pr-12"


def ok(*steps, ns=NS, protected=False):
    return check_plan(list(steps), ns, protected)


def test_standard_preview_deploy_allowed():
    v = ok(
        ("helm", ["upgrade", "--install", "pr-12", CHART_PATH, "-n", NS, "--create-namespace", "--wait",
                  "--set", "database.mode=embedded", "--set", "image.tag=sha-abc"]),
        ("kubectl", ["get", "svc", "-n", NS]),
    )
    assert v.allowed, v.violations


def test_flags_before_release_are_parsed():
    v = ok(("helm", ["upgrade", "-n", NS, "--install", "pr-12", CHART_PATH, "--set", "image.tag=x"]))
    assert v.allowed, v.violations


def test_teardown_allowed():
    assert ok(("helm", ["uninstall", "pr-12", "-n", NS]), ("kubectl", ["delete", "namespace", NS])).allowed


@pytest.mark.parametrize(
    "step,needle",
    [
        (("bash", ["-c", "rm -rf /"]), "not allowed"),
        (("kubectl", ["get", "pods", "-n", NS, ";", "curl", "evil"]), "metacharacters"),
        (("kubectl", ["get", "secrets", "-A"]), "forbidden"),
        (("kubectl", ["exec", "-n", NS, "pod", "--", "sh"]), "not an allowed operation"),
        (("kubectl", ["get", "pods"]), "must pass -n"),
        (("kubectl", ["get", "pods", "-n", "kube-system"]), "does not match"),
        (("kubectl", ["delete", "pod", "x", "-n", NS]), "only allowed for namespaces"),
        (("kubectl", ["delete", "namespace", "production"]), "does not match"),
        (("helm", ["upgrade", "--install", "pr-12", "oci://evil/chart", "-n", NS]), "chart must be"),
        (("helm", ["upgrade", "--install", "pr-12", CHART_PATH, "-n", NS, "--set", "database.url=x"]),
         "--set key"),
        (("helm", ["upgrade", "--install", "pr-12", CHART_PATH, "-n", NS, "--post-renderer", "x"]), "forbidden"),
        (("kubectl", ["scale", "deploy/pr-12-backend", "--replicas=50", "-n", NS]), "between 0 and 10"),
        (("kubectl", ["get", "pods", "-n", NS, "--kubeconfig=/tmp/x"]), "forbidden"),
    ],
)
def test_dangerous_steps_blocked(step, needle):
    v = ok(step)
    assert not v.allowed
    assert any(needle in m for m in v.violations), v.violations


def test_mutation_in_protected_namespace_blocked_but_reads_ok():
    assert not ok(("kubectl", ["rollout", "restart", "deploy/x", "-n", "production"]), ns="production").allowed
    assert ok(("kubectl", ["logs", "deploy/x", "-n", "production", "--tail=100"]), ns="production").allowed
    assert ok(("kubectl", ["rollout", "restart", "deploy/x", "-n", "production"]), ns="production",
              protected=True).allowed


def test_empty_and_oversized_plans():
    assert not ok().allowed
    assert not ok(*[("kubectl", ["get", "pods", "-n", NS])] * 13).allowed
