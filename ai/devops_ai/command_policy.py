"""Allow-list policy for AI-generated commands.

The model may propose any steps it likes; only steps that pass every rule here
are executed, without a shell (argv lists, no interpolation). The policy is
deliberately boring and fully unit-tested.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

CHART_PATH = "deploy/helm/idea-board"
PREVIEW_NS = re.compile(r"^preview-[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$")
RELEASE_NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$")
SHELL_META = re.compile(r"[;&|`$<>\\\n\r]|\$\(")

READ_ONLY = {
    "kubectl": {"get", "describe", "logs", "top"},
    "helm": {"status", "history", "list", "get"},
}
MUTATING = {
    "kubectl": {"scale", "rollout", "create", "delete", "wait", "label", "annotate"},
    "helm": {"upgrade", "install", "rollback", "uninstall"},
}
ROLLOUT_SUBCOMMANDS = {"status", "restart", "undo", "history"}
FORBIDDEN_FLAGS = {
    "--all-namespaces", "-A", "--kubeconfig", "--context", "--cluster", "--server", "-s",
    "--token", "--as", "--as-group", "--insecure-skip-tls-verify", "--post-renderer",
    "--repo", "--username", "--password", "--force", "--grace-period", "--raw",
}
# Helm --set keys a ChatOps user may influence. Everything else comes from values files.
ALLOWED_SET_KEYS = {
    "image.tag", "image.owner", "backend.replicas", "frontend.replicas",
    "backend.logLevel", "database.mode", "frontend.service.type",
}
ALLOWED_VALUES_FILES = re.compile(r"^deploy/helm/(idea-board/values\.yaml|values/[a-z0-9.-]+\.ya?ml)$")
MAX_STEPS = 12


@dataclass
class Verdict:
    allowed: bool
    violations: list[str] = field(default_factory=list)


VALUE_FLAGS = {"-n", "--namespace", "--timeout", "--set", "--set-string", "-f", "--values", "--version",
               "--description", "-o", "--output", "-l", "--selector", "--max"}


def _positionals(args: list[str]) -> list[str]:
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
        elif a in VALUE_FLAGS:
            skip = True
        elif not a.startswith("-"):
            out.append(a)
    return out


def _namespace_of(args: list[str]) -> str | None:
    for i, a in enumerate(args):
        if a in ("-n", "--namespace") and i + 1 < len(args):
            return args[i + 1]
        if a.startswith("--namespace="):
            return a.split("=", 1)[1]
    return None


def check_step(tool: str, args: list[str], namespace: str, protected_mutations_ok: bool = False) -> list[str]:
    v: list[str] = []
    if tool not in READ_ONLY:
        return [f"tool `{tool}` is not allowed (only kubectl, helm)"]
    if not args:
        return ["empty command"]
    for a in args:
        if SHELL_META.search(a):
            v.append(f"shell metacharacters in argument `{a}`")
        flag = a.split("=", 1)[0]
        if flag in FORBIDDEN_FLAGS:
            v.append(f"flag `{flag}` is forbidden")

    verb = args[0]
    mutating = verb in MUTATING[tool]
    if verb not in READ_ONLY[tool] and not mutating:
        v.append(f"`{tool} {verb}` is not an allowed operation")
        return v

    # Namespace scoping
    if tool == "kubectl" and verb in ("create", "delete"):
        if len(args) < 3 or args[1] not in ("namespace", "ns"):
            v.append(f"`kubectl {verb}` is only allowed for namespaces")
        elif args[2] != namespace:
            v.append(f"`kubectl {verb} namespace {args[2]}` does not match plan namespace `{namespace}`")
        elif not PREVIEW_NS.match(args[2]):
            v.append(f"namespace `{args[2]}` may not be created/deleted (only preview-*)")
    elif tool == "helm" and verb == "list":
        if _namespace_of(args) not in (namespace, None):
            v.append("helm list must target the plan namespace")
    else:
        ns = _namespace_of(args)
        if ns is None:
            v.append("every command must pass -n/--namespace explicitly")
        elif ns != namespace:
            v.append(f"namespace `{ns}` does not match plan namespace `{namespace}`")

    if mutating and not PREVIEW_NS.match(namespace) and not protected_mutations_ok:
        v.append(
            f"mutating `{tool} {verb}` in protected namespace `{namespace}` is not allowed from ChatOps; "
            "use the gated Deploy workflow"
        )

    if tool == "kubectl" and verb == "rollout" and (len(args) < 2 or args[1] not in ROLLOUT_SUBCOMMANDS):
        v.append("kubectl rollout subcommand must be one of " + ", ".join(sorted(ROLLOUT_SUBCOMMANDS)))
    if tool == "kubectl" and verb == "scale":
        for a in args:
            if a.startswith("--replicas="):
                try:
                    n = int(a.split("=", 1)[1])
                except ValueError:
                    n = -1
                if not 0 <= n <= 10:
                    v.append("replicas must be between 0 and 10")

    if tool == "helm" and verb in ("upgrade", "install"):
        positional = _positionals(args[1:])
        if len(positional) < 2:
            v.append("helm upgrade/install needs <release> <chart>")
        else:
            if not RELEASE_NAME.match(positional[0]):
                v.append(f"invalid release name `{positional[0]}`")
            if positional[1] != CHART_PATH:
                v.append(f"chart must be `{CHART_PATH}` (got `{positional[1]}`)")
        for i, a in enumerate(args):
            if a in ("--set", "--set-string") and i + 1 < len(args):
                for pair in args[i + 1].split(","):
                    key = pair.split("=", 1)[0]
                    if key not in ALLOWED_SET_KEYS:
                        v.append(f"helm --set key `{key}` is not allowed")
            if a.startswith(("--set-file", "--set-json", "--set-literal")):
                v.append(f"`{a.split('=')[0]}` is not allowed")
            if a in ("-f", "--values") and i + 1 < len(args) and not ALLOWED_VALUES_FILES.match(args[i + 1]):
                v.append(f"values file `{args[i + 1]}` is not allowed")
    return v


def check_plan(steps: list[tuple[str, list[str]]], namespace: str, protected_mutations_ok: bool = False) -> Verdict:
    violations: list[str] = []
    if not steps:
        violations.append("plan has no steps")
    if len(steps) > MAX_STEPS:
        violations.append(f"plan has {len(steps)} steps (max {MAX_STEPS})")
    if not re.match(r"^[a-z0-9]([a-z0-9-]{0,50}[a-z0-9])?$", namespace):
        violations.append(f"invalid namespace `{namespace}`")
    for i, (tool, args) in enumerate(steps, 1):
        violations += [f"step {i}: {msg}" for msg in check_step(tool, args, namespace, protected_mutations_ok)]
    return Verdict(allowed=not violations, violations=violations)
