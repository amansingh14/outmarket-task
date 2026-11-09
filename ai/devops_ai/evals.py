"""Evaluation harness for the AI features: `devops-ai eval [--offline]`.

Runs every case in ai/evals/cases.yaml through the production code path and checks outcomes.
Prints a Markdown scorecard; exits non-zero below --min-pass.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

import yaml

from . import chatops, health, plan_review, stack_profile
from .clouds import REPO
from .command_policy import MUTATING, PREVIEW_NS

CASES = REPO / "ai" / "evals" / "cases.yaml"


@dataclass
class Result:
    feature: str
    case: str
    passed: bool
    source: str
    detail: str


def _match(actual, expected) -> bool:
    if isinstance(expected, list):
        return actual in expected
    if isinstance(expected, dict):
        ok = True
        if "gte" in expected:
            ok &= actual is not None and actual >= expected["gte"]
        if "lte" in expected:
            ok &= actual is not None and actual <= expected["lte"]
        return ok
    return actual == expected


def _check(observed: dict, expect: dict) -> tuple[bool, str]:
    misses = [f"{k}={observed.get(k)!r} (want {v!r})" for k, v in expect.items() if not _match(observed.get(k), v)]
    return not misses, "; ".join(misses) or "ok"


def _stack(case: dict) -> Result:
    p, source, _ = stack_profile.propose(case["goal"], case["stack"])
    ok, detail = _check(p.model_dump(), case["expect"])
    return Result("stack_profile", case["id"], ok, source, detail)


def _chatops(case: dict) -> Result:
    ctx = chatops.Context(pr_number=42, image_owner="acme", image_tag="src-abc123")
    plan, source = chatops.plan(case["comment"], ctx)
    verdict = chatops.validate(plan)
    args = [a for s in plan.steps for a in s.args]
    mutating = [s for s in plan.steps if s.args and s.args[0] in MUTATING[s.tool]]
    observed = {
        "intent": plan.intent, "cloud": plan.cloud, "namespace": plan.namespace, "allowed": verdict.allowed,
        "args_contain": case["expect"].get("args_contain") if case["expect"].get("args_contain") in args else None,
        "read_only": not mutating,
        "allowed_or_unsupported": verdict.allowed or plan.intent == "unsupported",
        # Whatever the model proposed, nothing outside preview-* may ever be mutated.
        "never_mutates_protected": not (verdict.allowed and mutating and not PREVIEW_NS.match(plan.namespace)),
    }
    ok, detail = _check(observed, case["expect"])
    return Result("chatops", case["id"], ok, source, detail)


def _health(case: dict) -> Result:
    s = case["signals"]
    sig = health.Signals(
        namespace="eval", release="idea-board", pods=s.get("pods", []), warning_events=s.get("events", []),
        logs=s.get("logs", {}), probes=s.get("probes", []), api_status_counts=s.get("api_status_counts", {}),
        helm_history="", hard_failures=list(s.get("hard_failures", [])), baseline=s.get("baseline"),
    )
    sig.hard_failures += health.latency_regressions(sig.baseline, sig.probes)
    verdict, source = health.judge(sig)
    decision = health.decide(sig, verdict, threshold=0.7)
    ok, detail = _check({"verdict": verdict.verdict, "rollback": decision.rollback}, case["expect"])
    return Result("health", case["id"], ok, source, detail)


def _plan(case: dict) -> Result:
    plan_json = json.dumps({"resource_changes": [
        {"address": a, "type": t, "change": {"actions": acts, "before": {}, "after": {}}} for a, t, acts in case["changes"]
    ]})
    review, source = plan_review.review(plan_json, "aws", "eval")
    ok, detail = _check(review.model_dump(), case["expect"])
    return Result("plan_review", case["id"], ok, source, detail)


RUNNERS = {"stack_profile": _stack, "chatops": _chatops, "health": _health, "plan_review": _plan}


def run(offline: bool, path: Path = CASES) -> list[Result]:
    if offline:
        os.environ["DEVOPS_AI_OFFLINE"] = "1"
    cases = yaml.safe_load(path.read_text())
    results = []
    for feature, items in cases.items():
        for case in items:
            if offline and not case.get("offline"):
                continue
            try:
                results.append(RUNNERS[feature](case))
            except Exception as exc:  # noqa: BLE001 - an eval must report, not crash
                results.append(Result(feature, case["id"], False, "error", f"{type(exc).__name__}: {exc}"))
    return results


def to_markdown(results: list[Result], offline: bool) -> str:
    passed = sum(r.passed for r in results)
    mode = "offline fallbacks only" if offline else "live model"
    lines = [f"### AI evals ({mode}): {passed}/{len(results)} passed", "",
             "| Feature | Case | Result | Source | Detail |", "|---|---|---|---|---|"]
    for r in results:
        src = "ai" if r.source == "ai" else r.source.split(" ")[0]
        lines.append(f"| {r.feature} | `{r.case}` | {'✅' if r.passed else '❌'} | {src} | {r.detail} |")
    return "\n".join(lines)
