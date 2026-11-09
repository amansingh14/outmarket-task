"""devops-ai: AI copilots and delivery tooling for the Idea Board pipeline.

  devops-ai stack-profile    --stack nonprod --goal "cheapest shared non-prod under $150/mo"
  devops-ai render           --stack nonprod --cloud aws
  devops-ai chatops          --comment "/deploy-preview gcp" --pr 42 --image-owner acme --image-tag src-abc --execute
  devops-ai review-plan      --plan plan.json --cloud aws --stack nonprod
  devops-ai health-snapshot  --namespace qa --release idea-board --url http://lb --out baseline.json
  devops-ai health-check     --namespace qa --release idea-board --url http://lb --baseline baseline.json --rollback
  devops-ai scaffold-service --spec services/notifier.yaml
  devops-ai eval             [--offline]
  devops-ai delivery         resolve | infra | check-promotion | env-values | validate | compliance-matrix | clouds

Commands append Markdown to --summary (default: $GITHUB_STEP_SUMMARY if set), so results show up on
the workflow run page and can be posted to PRs.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

from . import chatops, clouds, delivery, evals, health, plan_review, scaffold, stack_profile
from .clouds import REPO


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


def _outputs(values: dict[str, str]) -> None:
    for k, v in values.items():
        _output(k, v)
        print(f"{k}={v}")


def _compact(obj) -> str:
    return json.dumps(obj, separators=(",", ":"))


# ------------------------------------------------------------------ AI commands
def cmd_stack_profile(a: argparse.Namespace) -> int:
    profile, source, notes = stack_profile.propose(a.goal, a.stack)
    out = Path(a.out or REPO / "config" / "stacks" / f"{a.stack}.yaml")
    stack_profile.save(profile, out, source="AI" if source == "ai" else "offline heuristic")
    rel = out.relative_to(REPO) if out.is_relative_to(REPO) else out
    _emit(stack_profile.to_markdown(profile, source, notes) + f"\n\nWritten to `{rel}`.", a.summary)
    return 0


def cmd_render(a: argparse.Namespace) -> int:
    profile = stack_profile.load(REPO / "config" / "stacks" / f"{a.stack}.yaml")
    tf, values = stack_profile.render(profile, a.cloud, Path(a.out_dir))
    _outputs({"tfvars": str(tf), "values": str(values)})
    return 0


def _chatops_context(a: argparse.Namespace) -> chatops.Context:
    return chatops.Context(pr_number=a.pr, image_owner=a.image_owner, image_tag=a.image_tag,
                           default_cloud=a.default_cloud)


def cmd_chatops(a: argparse.Namespace) -> int:
    ctx = _chatops_context(a)
    p, source = chatops.plan(a.comment, ctx)
    verdict = chatops.validate(p, ctx.available_clouds)
    results = None
    if verdict.allowed and a.execute and p.steps:
        results = chatops.execute(p)
    _outputs({"cloud": p.cloud, "intent": p.intent, "allowed": str(verdict.allowed).lower(), "namespace": p.namespace})
    md = chatops.to_markdown(p, source, verdict, results)
    if verdict.allowed and not a.execute and p.steps:
        md += "\n\n_Dry run: the plan was validated but not executed (no cluster configured for this cloud)._"
    _emit(md, a.summary)
    if not verdict.allowed:
        return 2
    if results and any(r["rc"] != 0 for r in results):
        return 1
    return 0


def cmd_chatops_target(a: argparse.Namespace) -> int:
    """Which cloud does this comment target? (Chooses credentials before planning for real.)"""
    p, _ = chatops.plan(a.comment, _chatops_context(a))
    _outputs({"cloud": p.cloud, "intent": p.intent})
    return 0


def cmd_review_plan(a: argparse.Namespace) -> int:
    plan_json = Path(a.plan).read_text()
    r, source = plan_review.review(plan_json, a.cloud, a.stack)
    _emit(plan_review.to_markdown(plan_json, r, source, a.cloud, a.stack), a.summary)
    destroy = plan_review.destructive_stateful(plan_review.parse(plan_json))
    _outputs({"risk": r.risk, "destructive": str(bool(destroy)).lower()})
    if skips := plan_review.version_skips(plan_json):
        for s in skips:
            print(f"::error::{s.replace('`', '')}", file=sys.stderr)
        return 3
    if destroy and not a.allow_destructive:
        print("::error::plan destroys stateful resources; re-run with allow_destructive", file=sys.stderr)
        return 3
    return 0


def cmd_health_snapshot(a: argparse.Namespace) -> int:
    snap = health.snapshot(a.namespace, a.release, a.url)
    Path(a.out).write_text(json.dumps(snap, indent=2))
    print(f"baseline: {'release ' + str(snap.get('revision')) if snap.get('exists') else 'no existing release'}")
    return 0


def cmd_health(a: argparse.Namespace) -> int:
    baseline = None
    if a.baseline and Path(a.baseline).exists():
        baseline = json.loads(Path(a.baseline).read_text())
        if not baseline.get("exists"):
            baseline = None
    sig = health.collect(a.namespace, a.release, a.url, a.probe_requests, a.probe_interval, baseline=baseline)
    if a.helm_failed:
        # e.g. a pre-upgrade hook (migration) failed: old pods still serve, but the release is broken.
        sig.hard_failures.insert(0, f"helm upgrade failed: {a.helm_failed[:300]}")
    verdict, source = health.judge(sig)
    decision = health.decide(sig, verdict, a.confidence_threshold)
    rb_out = None
    if decision.rollback and a.rollback:
        rb_out = health.rollback(a.namespace, a.release)
    _emit(health.to_markdown(sig, verdict, source, decision, rb_out), a.summary)
    if a.report:
        Path(a.report).write_text(health.report_json(sig, verdict, source, decision))
    _outputs({"verdict": verdict.verdict, "rolled_back": str(rb_out is not None).lower()})
    return 1 if decision.rollback else 0


def cmd_scaffold(a: argparse.Namespace) -> int:
    spec = scaffold.load_spec(Path(a.spec))
    bp, source, notes = scaffold.design(spec)
    path = scaffold.render(spec, bp, Path(a.out_dir), source="AI" if source == "ai" else "offline template")
    rel = path.relative_to(REPO) if path.resolve().is_relative_to(REPO) else path
    md = [f"### Scaffolded `{spec.name}` → `{rel}`", f"_Designer: {source}_", "", bp.notes]
    if notes:
        md += ["", "**Guardrail adjustments (enforced by policy, not by the AI):**", *[f"- {n}" for n in notes]]
    _emit("\n".join(md), a.summary)
    _outputs({"values": str(rel), "service": spec.name})
    return 0


def cmd_eval(a: argparse.Namespace) -> int:
    results = evals.run(offline=a.offline)
    _emit(evals.to_markdown(results, a.offline), a.summary)
    rate = sum(r.passed for r in results) / max(len(results), 1)
    return 0 if rate >= a.min_pass else 1


# ------------------------------------------------------------- delivery model
def _delivery() -> delivery.Delivery:
    return delivery.load(REPO / "config" / "deployments.yaml")


def cmd_delivery_resolve(a: argparse.Namespace) -> int:
    """Branch (or environment) -> environment, deploy matrix, stack to apply, promotion target."""
    d = _delivery()
    env = d.environments.get(a.environment) if a.environment else d.by_branch(a.branch)
    if env is None:
        _outputs({"environment": "", "apply_stack": ""})
        print(f"branch `{a.branch}` does not deploy anywhere")
        return 0
    _outputs({
        "environment": env.name, "branch": env.branch, "stack": env.stack, "approval": str(env.approval).lower(),
        "apply_stack": d.stack_for_branch(env.branch) or "",
        "promote_to": d.environments[env.promote_to].branch if env.promote_to else "",
        "backmerge_to": d.promotion["backmerge_to"] if env.branch == d.promotion["backmerge_from"] else "",
        "matrix": _compact(d.deploy_matrix(env.name)),
    })
    return 0


def cmd_delivery_infra(a: argparse.Namespace) -> int:
    """Branch (or explicit stack) -> stack and per-cloud matrix."""
    d = _delivery()
    stack = a.stack or d.stack_for_branch(a.branch or "")
    if not stack:
        _outputs({"stack": ""})
        return 0
    if stack not in d.stacks:
        print(f"unknown stack {stack}", file=sys.stderr)
        return 2
    _outputs({"stack": stack, "matrix": _compact(d.infra_matrix(stack))})
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
    print(f"deployments.yaml OK · clouds: {', '.join(clouds.names())} · path: " + " → ".join(d.path()))
    for e in d.environments.values():
        print(f"  {e.name:<12} branch={e.branch:<12} stack={e.stack:<10} clouds={','.join(e.clouds):<8} "
              f"ns={e.namespace:<12} db={e.database}")
    return 0


def cmd_delivery_compliance(a: argparse.Namespace) -> int:
    m = _delivery().compliance_matrix()
    _outputs({"matrix": _compact(m), "columns": ",".join(f"{i['cloud']}/{i['stack']}" for i in m["include"]),
              "clouds": ",".join(sorted({i["cloud"] for i in m["include"]}))})
    return 0


def cmd_delivery_clouds(a: argparse.Namespace) -> int:
    if a.cloud:
        c = clouds.get(a.cloud)
        _outputs({"vars": " ".join(c.github_vars.get(a.purpose, [])), "terraform_root": c.terraform_root})
    else:
        _outputs({"clouds": _compact(clouds.names())})
    return 0


# --------------------------------------------------------------------- parser
def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "WARNING"))
    cloud_names = clouds.names()
    ap = argparse.ArgumentParser(prog="devops-ai", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--summary", help="append Markdown here (default $GITHUB_STEP_SUMMARY)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("stack-profile", help="goal -> config/stacks/<stack>.yaml (dynamic environment config)")
    s.add_argument("--stack", required=True)
    s.add_argument("--goal", required=True)
    s.add_argument("--out")
    s.set_defaults(fn=cmd_stack_profile)

    s = sub.add_parser("render", help="stack profile -> tfvars + helm values for a cloud")
    s.add_argument("--stack", required=True)
    s.add_argument("--cloud", required=True, choices=cloud_names)
    s.add_argument("--out-dir", default="build")
    s.set_defaults(fn=cmd_render)

    for name, fn in (("chatops", cmd_chatops), ("chatops-target", cmd_chatops_target)):
        s = sub.add_parser(name, help="PR comment -> validated kubectl/helm plan")
        s.add_argument("--comment", required=True)
        s.add_argument("--pr", type=int, required=True)
        s.add_argument("--image-owner", required=True)
        s.add_argument("--image-tag", required=True)
        s.add_argument("--default-cloud", default="", choices=["", *cloud_names])
        if name == "chatops":
            s.add_argument("--execute", action="store_true", help="run the plan if policy allows")
        s.set_defaults(fn=fn)

    s = sub.add_parser("review-plan", help="terraform show -json -> risk review + destructive gate")
    s.add_argument("--plan", required=True)
    s.add_argument("--cloud", required=True)
    s.add_argument("--stack", required=True)
    s.add_argument("--allow-destructive", action="store_true")
    s.set_defaults(fn=cmd_review_plan)

    s = sub.add_parser("health-snapshot", help="baseline of the current release, taken before an upgrade")
    s.add_argument("--namespace", required=True)
    s.add_argument("--release", required=True)
    s.add_argument("--url")
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_health_snapshot)

    s = sub.add_parser("health-check", help="post-deploy health verdict (+ rollback)")
    s.add_argument("--namespace", required=True)
    s.add_argument("--release", required=True)
    s.add_argument("--url")
    s.add_argument("--baseline", help="JSON from health-snapshot")
    s.add_argument("--helm-failed", default="", metavar="REASON", help="helm upgrade failed (treated as a hard gate)")
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

    s = sub.add_parser("eval", help="run the AI evaluation set (ai/evals/cases.yaml)")
    s.add_argument("--offline", action="store_true", help="fallbacks only (no API key needed)")
    s.add_argument("--min-pass", type=float, default=1.0, help="minimum pass rate (0-1)")
    s.set_defaults(fn=cmd_eval)

    s = sub.add_parser("delivery", help="branching / environment model (config/deployments.yaml)")
    dsub = s.add_subparsers(dest="delivery_cmd", required=True)
    x = dsub.add_parser("resolve", help="branch or environment -> deploy matrix, stack to apply, next branch")
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
    x = dsub.add_parser("compliance-matrix", help="(cloud, stack) pairs that are actually deployed")
    x.set_defaults(fn=cmd_delivery_compliance)
    x = dsub.add_parser("clouds", help="list cloud plugins, or a cloud's required GitHub variables")
    x.add_argument("--cloud", default="")
    x.add_argument("--purpose", default="deploy", choices=["deploy", "plan"])
    x.set_defaults(fn=cmd_delivery_clouds)

    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
