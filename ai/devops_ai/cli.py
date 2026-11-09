"""devops-ai: AI copilots for the delivery pipeline.

  devops-ai env-profile     --env staging --goal "cost-sensitive staging under $150/mo"
  devops-ai render          --env staging --cloud aws
  devops-ai chatops         --comment "/deploy-preview gcp" --pr 42 --image-tag sha-abc --execute
  devops-ai review-plan     --plan plan.json --cloud aws --env staging
  devops-ai health-check    --namespace idea-board --release idea-board --url http://1.2.3.4 --rollback
  devops-ai scaffold-service --spec services/notifier.yaml

Every command writes Markdown to --summary (default: $GITHUB_STEP_SUMMARY if set)
so results show up on the run page and can be posted to the PR.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

from . import chatops, delivery, env_profile, health, plan_review, scaffold

REPO = Path(os.getenv("GITHUB_WORKSPACE", Path(__file__).resolve().parents[2]))


def _emit(md: str, summary: str | None) -> None:
    print(md)
    target = summary or os.getenv("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a") as f:
            f.write(md + "\n\n")


def _output(key: str, value: str) -> None:
    if path := os.getenv("GITHUB_OUTPUT"):
        with open(path, "a") as f:
            f.write(f"{key}={value}\n")


def cmd_env_profile(a: argparse.Namespace) -> int:
    profile, source, notes = env_profile.propose(a.goal, a.env)
    out = Path(a.out or REPO / "config" / "environments" / f"{a.env}.yaml")
    env_profile.save(profile, out)
    _emit(env_profile.to_markdown(profile, source, notes) + f"\n\nWritten to `{out.relative_to(REPO)}`.", a.summary)
    return 0


def cmd_render(a: argparse.Namespace) -> int:
    src = REPO / "config" / "environments" / f"{a.env}.yaml"
    profile = env_profile.load(src)
    tf, values = env_profile.render(profile, a.cloud, Path(a.out_dir))
    _output("tfvars", str(tf))
    _output("values", str(values))
    print(f"wrote {tf}\nwrote {values}")
    return 0


def cmd_chatops(a: argparse.Namespace) -> int:
    ctx = chatops.Context(pr_number=a.pr, image_owner=a.image_owner, image_tag=a.image_tag,
                          default_cloud=a.default_cloud)
    p, source = chatops.plan(a.comment, ctx)
    verdict = chatops.validate(p)
    results = None
    if verdict.allowed and a.execute and p.steps:
        results = chatops.execute(p)
    _output("cloud", p.cloud)
    _output("intent", p.intent)
    _output("allowed", str(verdict.allowed).lower())
    _output("namespace", p.namespace)
    _emit(chatops.to_markdown(p, source, verdict, results), a.summary)
    if not verdict.allowed:
        return 2
    if results and any(r["rc"] != 0 for r in results):
        return 1
    return 0


def cmd_plan_only(a: argparse.Namespace) -> int:
    """Print the plan's target cloud without executing (used to choose credentials first)."""
    ctx = chatops.Context(pr_number=a.pr, image_owner=a.image_owner, image_tag=a.image_tag,
                          default_cloud=a.default_cloud)
    p, _ = chatops.plan(a.comment, ctx)
    _output("cloud", p.cloud)
    _output("intent", p.intent)
    print(p.cloud)
    return 0


def cmd_review_plan(a: argparse.Namespace) -> int:
    plan_json = Path(a.plan).read_text()
    r, source = plan_review.review(plan_json, a.cloud, a.env)
    _emit(plan_review.to_markdown(plan_json, r, source, a.cloud, a.env), a.summary)
    destroy = plan_review.destructive_stateful(plan_review.parse(plan_json))
    _output("risk", r.risk)
    _output("destructive", str(bool(destroy)).lower())
    if destroy and not a.allow_destructive:
        print("::error::plan destroys stateful resources; re-run with allow_destructive", file=sys.stderr)
        return 3
    return 0


def cmd_health(a: argparse.Namespace) -> int:
    sig = health.collect(a.namespace, a.release, a.url, a.probe_requests, a.probe_interval)
    verdict, source = health.judge(sig)
    decision = health.decide(sig, verdict, a.confidence_threshold)
    rb_out = None
    if decision.rollback and a.rollback:
        rb_out = health.rollback(a.namespace, a.release)
    _emit(health.to_markdown(sig, verdict, source, decision, rb_out), a.summary)
    if a.report:
        Path(a.report).write_text(health.report_json(sig, verdict, source, decision))
    _output("verdict", verdict.verdict)
    _output("rolled_back", str(bool(rb_out is not None)).lower())
    return 1 if decision.rollback else 0


def cmd_scaffold(a: argparse.Namespace) -> int:
    spec = scaffold.load_spec(Path(a.spec))
    bp, source, notes = scaffold.design(spec)
    path = scaffold.render(spec, bp, Path(a.out_dir))
    md = [f"### Scaffolded `{spec.name}` → `{path}`", f"_Designer: {source}_", "", bp.notes]
    if notes:
        md += ["", "**Guardrail adjustments:**", *[f"- {n}" for n in notes]]
    _emit("\n".join(md), a.summary)
    return 0


def _delivery() -> delivery.Delivery:
    return delivery.load(REPO / "config" / "deployments.yaml")


def cmd_delivery_resolve(a: argparse.Namespace) -> int:
    """Branch -> environment, deploy matrix and promotion target (for deploy.yml)."""
    d = _delivery()
    env = d.environments.get(a.environment) if a.environment else d.by_branch(a.branch)
    if env is None:
        _output("environment", "")
        print(f"branch `{a.branch}` does not deploy anywhere")
        return 0
    nxt = d.environments[env.promote_to].branch if env.promote_to else ""
    outputs = {
        "environment": env.name, "branch": env.branch, "stack": env.stack, "approval": str(env.approval).lower(),
        "promote_to": nxt, "matrix": json.dumps(d.deploy_matrix(env.name), separators=(",", ":")),
        "backmerge_to": d.promotion["backmerge_to"] if env.branch == d.promotion["backmerge_from"] else "",
    }
    for k, v in outputs.items():
        _output(k, v)
        print(f"{k}={v}")
    return 0


def cmd_delivery_infra(a: argparse.Namespace) -> int:
    """Branch (or explicit stack) -> stack and per-cloud matrix (for infra.yml)."""
    d = _delivery()
    stack = a.stack or d.stack_for_branch(a.branch or "")
    if not stack:
        _output("stack", "")
        print(f"branch `{a.branch}` does not apply any infrastructure stack")
        return 0
    if stack not in d.stacks:
        print(f"unknown stack {stack}", file=sys.stderr)
        return 2
    for k, v in {"stack": stack, "profile": d.stacks[stack]["profile"],
                 "matrix": json.dumps(d.infra_matrix(stack), separators=(",", ":"))}.items():
        _output(k, v)
        print(f"{k}={v}")
    return 0


def cmd_delivery_check(a: argparse.Namespace) -> int:
    ok, reason = _delivery().check_promotion(a.base, a.head)
    _emit(f"### {'✅' if ok else '❌'} Branch policy\n\n{reason}", a.summary)
    return 0 if ok else 1


def cmd_delivery_values(a: argparse.Namespace) -> int:
    import yaml

    values = _delivery().env_values(a.env, REPO)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(yaml.safe_dump(values, sort_keys=False))
    print(f"wrote {a.out}")
    return 0


def cmd_delivery_validate(a: argparse.Namespace) -> int:
    d = _delivery()
    print("deployments.yaml OK · path: " + " → ".join(d.path()))
    for e in d.environments.values():
        print(f"  {e.name:<12} branch={e.branch:<12} stack={e.stack:<10} clouds={','.join(e.clouds):<8} "
              f"ns={e.namespace:<12} db={e.database}")
    return 0


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "WARNING"))
    ap = argparse.ArgumentParser(prog="devops-ai", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--summary", help="append Markdown here (default $GITHUB_STEP_SUMMARY)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("env-profile", help="goal -> config/environments/<env>.yaml")
    s.add_argument("--env", required=True)
    s.add_argument("--goal", required=True)
    s.add_argument("--out")
    s.set_defaults(fn=cmd_env_profile)

    s = sub.add_parser("render", help="env profile -> tfvars + helm values for a cloud")
    s.add_argument("--env", required=True)
    s.add_argument("--cloud", required=True, choices=["aws", "gcp"])
    s.add_argument("--out-dir", default="build")
    s.set_defaults(fn=cmd_render)

    for name, fn in (("chatops", cmd_chatops), ("chatops-target", cmd_plan_only)):
        s = sub.add_parser(name, help="PR comment -> validated kubectl/helm plan")
        s.add_argument("--comment", required=True)
        s.add_argument("--pr", type=int, required=True)
        s.add_argument("--image-owner", required=True)
        s.add_argument("--image-tag", required=True)
        s.add_argument("--default-cloud", default="aws", choices=["aws", "gcp"])
        if name == "chatops":
            s.add_argument("--execute", action="store_true", help="run the plan if policy allows")
        s.set_defaults(fn=fn)

    s = sub.add_parser("review-plan", help="terraform show -json -> risk review + destructive gate")
    s.add_argument("--plan", required=True)
    s.add_argument("--cloud", required=True)
    s.add_argument("--env", required=True)
    s.add_argument("--allow-destructive", action="store_true")
    s.set_defaults(fn=cmd_review_plan)

    s = sub.add_parser("health-check", help="post-deploy health verdict (+ rollback)")
    s.add_argument("--namespace", required=True)
    s.add_argument("--release", required=True)
    s.add_argument("--url")
    s.add_argument("--probe-requests", type=int, default=60)
    s.add_argument("--probe-interval", type=float, default=0.5)
    s.add_argument("--confidence-threshold", type=float, default=0.7)
    s.add_argument("--rollback", action="store_true")
    s.add_argument("--report")
    s.set_defaults(fn=cmd_health)

    s = sub.add_parser("scaffold-service", help="service spec -> helm values (generative IaC)")
    s.add_argument("--spec", required=True)
    s.add_argument("--out-dir", default=str(REPO / "deploy" / "helm" / "values" / "services"))
    s.set_defaults(fn=cmd_scaffold)

    s = sub.add_parser("delivery", help="branching / environment model (config/deployments.yaml)")
    dsub = s.add_subparsers(dest="delivery_cmd", required=True)
    x = dsub.add_parser("resolve", help="branch -> environment + deploy matrix")
    x.add_argument("--branch", default="")
    x.add_argument("--environment", default="")
    x.set_defaults(fn=cmd_delivery_resolve)
    x = dsub.add_parser("infra", help="branch or stack -> terraform matrix")
    x.add_argument("--branch", default="")
    x.add_argument("--stack", default="")
    x.set_defaults(fn=cmd_delivery_infra)
    x = dsub.add_parser("check-promotion", help="is a PR head -> base allowed?")
    x.add_argument("--base", required=True)
    x.add_argument("--head", required=True)
    x.set_defaults(fn=cmd_delivery_check)
    x = dsub.add_parser("env-values", help="helm values for an environment")
    x.add_argument("--env", required=True)
    x.add_argument("--out", required=True)
    x.set_defaults(fn=cmd_delivery_values)
    x = dsub.add_parser("validate", help="validate deployments.yaml and print the model")
    x.set_defaults(fn=cmd_delivery_validate)

    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
