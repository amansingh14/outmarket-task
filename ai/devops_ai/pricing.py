"""Rough monthly cost model (USD, on-demand list prices, 730 h/month).

The model never estimates cost itself; it would make numbers up. It picks size classes, and the
price table in each cloud plugin (clouds/<name>/cloud.yaml) prices them deterministically, so a
proposed profile can be checked against the budget in the developer's goal.
Excludes egress, logging and taxes. Treat the result as an order of magnitude.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import clouds

if TYPE_CHECKING:
    from .stack_profile import StackProfile


def estimate_monthly_cost(profile: StackProfile, cloud: str) -> dict[str, float]:
    p = clouds.get(cloud).pricing
    nodes = p["node"][profile.node_size] * profile.node_desired
    if profile.spot_nodes:
        nodes *= 1 - p["spot_discount"]
    ha = 2 if profile.db_high_availability else 1
    database = (p["database"][profile.db_size] + p["database_storage_per_gb"] * profile.db_storage_gb) * ha
    nat = p["nat_gateway"] * (p["nat_gateways_when_ha"] if profile.db_high_availability else 1)
    breakdown = {
        "control_plane": p["control_plane"]["zonal" if profile.zonal_control_plane else "regional"],
        "nodes": nodes,
        "database": database,
        "networking": nat + p["load_balancer"],
    }
    breakdown = {k: round(v, 2) for k, v in breakdown.items()}
    breakdown["total"] = round(sum(breakdown.values()), 2)
    return breakdown
