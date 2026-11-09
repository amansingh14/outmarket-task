"""Delivery model: which branch deploys where, and which PRs are allowed.

Single source of truth is config/deployments.yaml. The CI/CD workflows call the
`devops-ai delivery ...` subcommands instead of hard-coding branch names, so the
branching model, cloud placement and promotion order live in one reviewed file.
"""

from __future__ import annotations

import copy
import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from . import env_profile

DB_NAME = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
K8S_NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")


@dataclass
class Environment:
    name: str
    branch: str
    stack: str
    clouds: list[str]
    namespace: str
    database: str
    create_database: bool = False
    promote_to: str | None = None
    approval: bool = False
    helm: dict = field(default_factory=dict)


@dataclass
class Delivery:
    registry: str
    stacks: dict[str, dict]
    environments: dict[str, Environment]
    promotion: dict

    # ------------------------------------------------------------- lookups
    def by_branch(self, branch: str) -> Environment | None:
        return next((e for e in self.environments.values() if e.branch == branch), None)

    def long_lived_branches(self) -> list[str]:
        return [e.branch for e in self.environments.values()]

    def stack_for_branch(self, branch: str) -> str | None:
        return next((s for s, cfg in self.stacks.items() if cfg["apply_from"] == branch), None)

    def stack_clouds(self, stack: str) -> list[str]:
        clouds = {c for e in self.environments.values() if e.stack == stack for c in e.clouds}
        return sorted(clouds)

    def stack_environments(self, stack: str) -> list[Environment]:
        return [e for e in self.environments.values() if e.stack == stack]

    # ----------------------------------------------------------- promotion
    def allowed_targets(self, head: str) -> list[str]:
        p = self.promotion
        if any(head.startswith(prefix) for prefix in p["feature_prefixes"]):
            return [p["feature_target"]]
        if head.startswith(p["hotfix_prefix"]):
            return [p["hotfix_target"]]
        targets = []
        env = self.by_branch(head)
        if env and env.promote_to:
            targets.append(self.environments[env.promote_to].branch)
        if head == p["backmerge_from"]:
            targets.append(p["backmerge_to"])
        return targets

    def check_promotion(self, base: str, head: str) -> tuple[bool, str]:
        if base not in self.long_lived_branches():
            return True, f"`{base}` is not a managed environment branch; no promotion rule applies."
        targets = self.allowed_targets(head)
        if base in targets:
            return True, f"`{head}` → `{base}` follows the promotion path."
        if not targets:
            prefixes = ", ".join(f"`{p}*`" for p in self.promotion["feature_prefixes"])
            return False, (f"Branch `{head}` has no promotion rule. Name feature branches {prefixes} "
                           f"(they merge into `{self.promotion['feature_target']}`) or "
                           f"`{self.promotion['hotfix_prefix']}*` for production hotfixes.")
        return False, (f"`{head}` may only merge into {', '.join(f'`{t}`' for t in targets)}, not `{base}`. "
                       f"Path: {' → '.join(self.path())}.")

    def path(self) -> list[str]:
        start = self.environments[self.by_branch(self.promotion["feature_target"]).name]
        order, env = [], start
        while env:
            order.append(env.branch)
            env = self.environments.get(env.promote_to) if env.promote_to else None
        return order

    # --------------------------------------------------------------- matrix
    def deploy_matrix(self, env_name: str) -> dict:
        e = self.environments[env_name]
        return {"include": [{"environment": e.name, "cloud": c, "stack": e.stack, "namespace": e.namespace,
                             "database": e.database} for c in e.clouds]}

    def infra_matrix(self, stack: str) -> dict:
        return {"include": [{"stack": stack, "cloud": c} for c in self.stack_clouds(stack)]}

    # --------------------------------------------------------------- values
    def env_values(self, env_name: str, repo: Path) -> dict:
        """Helm values for one environment: stack sizing profile + per-env overrides + DB wiring."""
        e = self.environments[env_name]
        profile = env_profile.load(repo / "config" / "environments" / f"{self.stacks[e.stack]['profile']}.yaml")
        values = env_profile.helm_values(profile)
        _deep_merge(values, copy.deepcopy(e.helm))
        if any(_get(e.helm, [c, "replicas"]) for c in ("backend", "frontend")):
            # Fixed replica overrides only make sense without an HPA fighting them.
            for c in ("backend", "frontend"):
                values[c]["autoscaling"]["enabled"] = False
                values[c]["autoscaling"]["minReplicas"] = values[c]["replicas"]
        values["podDisruptionBudget"] = {"enabled": values["backend"]["replicas"] > 1}
        values["database"] = {"mode": "external", "existingSecret": "idea-board-db",
                              "createDatabase": e.create_database, "name": e.database}
        values["environment"] = e.name
        return values


def _get(d: dict, path: list[str]):
    for k in path:
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def _deep_merge(base: dict, override: dict) -> dict:
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def load(path: Path) -> Delivery:
    raw = yaml.safe_load(path.read_text())
    envs = {name: Environment(name=name, **cfg) for name, cfg in raw["environments"].items()}
    d = Delivery(registry=raw["registry"], stacks=raw["stacks"], environments=envs, promotion=raw["promotion"])
    validate(d)
    return d


def validate(d: Delivery) -> None:
    errors = []
    branches = [e.branch for e in d.environments.values()]
    if len(set(branches)) != len(branches):
        errors.append("two environments share a branch")
    for e in d.environments.values():
        if e.stack not in d.stacks:
            errors.append(f"{e.name}: unknown stack {e.stack}")
        if not e.clouds or not set(e.clouds) <= {"aws", "gcp"}:
            errors.append(f"{e.name}: clouds must be a non-empty subset of [aws, gcp]")
        if e.promote_to and e.promote_to not in d.environments:
            errors.append(f"{e.name}: promote_to {e.promote_to} is not an environment")
        if not DB_NAME.match(e.database):
            errors.append(f"{e.name}: invalid database name {e.database!r}")
        if not K8S_NAME.match(e.namespace):
            errors.append(f"{e.name}: invalid namespace {e.namespace!r}")
    # Two environments on the same stack and cloud must not collide.
    seen: dict[tuple, str] = {}
    for e in d.environments.values():
        for c in e.clouds:
            for key in ((e.stack, c, "ns", e.namespace), (e.stack, c, "db", e.database)):
                if key in seen:
                    errors.append(f"{e.name} and {seen[key]} share {key[2]} `{key[3]}` on {e.stack}/{c}")
                seen[key] = e.name
    shared = [s for s in d.stacks if len(d.stack_environments(s)) > 1]
    for s in shared:
        for e in d.stack_environments(s):
            if not e.create_database:
                errors.append(f"{e.name}: shares stack {s}, so create_database must be true")
    # Promotion chain must be acyclic.
    for e in d.environments.values():
        hops, cur = set(), e
        while cur.promote_to:
            if cur.name in hops:
                errors.append(f"promotion cycle at {cur.name}")
                break
            hops.add(cur.name)
            cur = d.environments[cur.promote_to]
    if errors:
        raise ValueError("config/deployments.yaml is invalid:\n- " + "\n- ".join(errors))
