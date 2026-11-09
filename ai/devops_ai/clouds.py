"""Cloud plugin registry: one folder per cloud under clouds/<name>/.

Nothing in the Python code or the pipelines lists cloud names; they ask this registry.
Adding a cloud means adding clouds/<name>/cloud.yaml (plus its Terraform root and policy package).
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import yaml

REPO = Path(os.getenv("GITHUB_WORKSPACE", Path(__file__).resolve().parents[2]))


@dataclass(frozen=True)
class Cloud:
    name: str
    display: str
    kubernetes: str
    database: str
    terraform_root: str
    github_vars: dict
    pricing: dict


@lru_cache
def registry(root: Path = REPO) -> dict[str, Cloud]:
    clouds = {}
    for f in sorted((root / "clouds").glob("*/cloud.yaml")):
        raw = yaml.safe_load(f.read_text())
        if raw["name"] != f.parent.name:
            raise ValueError(f"{f}: name must match its folder")
        clouds[raw["name"]] = Cloud(**raw)
    if not clouds:
        raise RuntimeError(f"no cloud plugins found under {root / 'clouds'}")
    return clouds


def names() -> list[str]:
    return list(registry())


def get(name: str) -> Cloud:
    try:
        return registry()[name]
    except KeyError:
        raise ValueError(f"unknown cloud {name!r}; available: {', '.join(names())}") from None
