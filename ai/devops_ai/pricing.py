"""Rough monthly cost model (USD, on-demand list prices, 730 h/month).

The model never estimates cost itself; it would make numbers up. It picks
size classes, and this table prices them deterministically so the proposed
config can be checked against the budget in the developer's stated goal.
Excludes egress, logging and taxes. Treat the result as an order of magnitude.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .env_profile import EnvProfile

NODE = {
    "aws": {"small": 30.4, "medium": 60.7, "large": 140.2},   # t3.medium / t3.large / m6i.xlarge
    "gcp": {"small": 24.5, "medium": 48.9, "large": 97.8},    # e2-medium / e2-standard-2 / e2-standard-4
}
DB = {
    "aws": {"small": 11.7, "medium": 47.5, "large": 113.2},   # db.t4g.micro / medium / db.m6g.large
    "gcp": {"small": 7.7, "medium": 80.7, "large": 101.1},    # db-f1-micro / custom-2-4096 / custom-2-8192
}
DB_STORAGE_PER_GB = {"aws": 0.115, "gcp": 0.17}
SPOT_DISCOUNT = {"aws": 0.65, "gcp": 0.70}
NAT = {"aws": 32.9, "gcp": 32.0}
LOAD_BALANCER = {"aws": 18.0, "gcp": 18.3}


def control_plane(cloud: str, zonal: bool) -> float:
    if cloud == "aws":
        return 73.0
    # GKE's free tier credit covers one zonal cluster's management fee.
    return 0.0 if zonal else 73.0


def estimate_monthly_cost(profile: "EnvProfile", cloud: str) -> dict[str, float]:
    nodes = NODE[cloud][profile.node_size] * profile.node_desired
    if profile.spot_nodes:
        nodes *= 1 - SPOT_DISCOUNT[cloud]
    ha = 2 if profile.db_high_availability else 1
    db = DB[cloud][profile.db_size] * ha
    storage = DB_STORAGE_PER_GB[cloud] * profile.db_storage_gb * ha
    nat = NAT[cloud] * (3 if (cloud == "aws" and profile.db_high_availability) else 1)
    breakdown = {
        "control_plane": control_plane(cloud, profile.zonal_control_plane),
        "nodes": nodes,
        "database": db + storage,
        "networking": nat + LOAD_BALANCER[cloud],
    }
    breakdown = {k: round(v, 2) for k, v in breakdown.items()}
    breakdown["total"] = round(sum(breakdown.values()), 2)
    return breakdown
