#!/usr/bin/env python3
"""Build the Terraform compliance PR comment from CI artifacts.

Inputs (all optional except the catalog), in --results:
  validate-<cloud>.json          {"cloud", "fmt", "init", "validate": <terraform validate -json>}
  opa-test.json                  {"status": "pass|fail", "output": "..."}
  conftest-<cloud>-<env>.json    conftest -o json output
  status-<cloud>-<env>.json      {"status": "skipped|plan_failed", "reason": "..."}

Output: Markdown on stdout (or --out). Exit code 1 if anything blocks the merge:
fmt/validate failure, failing policy unit tests, a failed plan, or any high-severity finding.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import yaml

MARKER = "<!-- terraform-compliance-report -->"
ICON = {"pass": "✅", "fail": "❌", "warn": "⚠️", "waived": "🟦", "na": "➖", "skipped": "⏭️", "error": "💥"}


def load_json(p: Path):
    try:
        return json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def findings_from_conftest(doc) -> list[dict]:
    out = []
    for ns in doc or []:
        for kind, key in (("fail", "failures"), ("warn", "warnings")):
            for f in ns.get(key) or []:
                meta = f.get("metadata") or {}
                d = meta.get("details", meta)
                if not d.get("id"):
                    d = {"id": "UNKNOWN", "resource": "?", "message": f.get("msg", ""), "severity": "high"}
                out.append({**d, "kind": "waived" if d.get("waived") else kind})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--catalog", default="policy/data/catalog.yaml")
    ap.add_argument("--clouds", default="aws,gcp")
    ap.add_argument("--envs", default="nonprod,preprod,production")
    ap.add_argument("--out")
    a = ap.parse_args()

    res = Path(a.results)
    catalog: dict = yaml.safe_load(Path(a.catalog).read_text())["catalog"]
    clouds, envs = a.clouds.split(","), a.envs.split(",")
    columns = [(c, e) for c in clouds for e in envs]
    blocking: list[str] = []

    # ---------------------------------------------------------------- validate
    validate_rows = []
    for c in clouds:
        v = load_json(res / f"validate-{c}.json")
        if v is None:
            validate_rows.append(f"| `envs/{c}` | {ICON['skipped']} | {ICON['skipped']} | {ICON['skipped']} | job did not report |")
            blocking.append(f"validate results missing for {c}")
            continue
        diags = (v.get("validate") or {}).get("diagnostics") or []
        errors = [d for d in diags if d.get("severity") == "error"]
        warns = [d for d in diags if d.get("severity") == "warning"]
        valid = (v.get("validate") or {}).get("valid") is True
        notes = "; ".join(f"{d.get('summary')} ({(d.get('range') or {}).get('filename', '')})" for d in errors[:3])
        if warns:
            notes = (notes + "; " if notes else "") + f"{len(warns)} warning(s)"
        row = [ICON["pass" if v.get(k) == "pass" else "fail"] for k in ("fmt", "init")]
        validate_rows.append(f"| `envs/{c}` | {row[0]} | {row[1]} | {ICON['pass' if valid else 'fail']} | {notes or '–'} |")
        if v.get("fmt") != "pass":
            blocking.append(f"terraform fmt ({c})")
        if v.get("init") != "pass" or not valid:
            blocking.append(f"terraform validate ({c})")

    opa = load_json(res / "opa-test.json") or {"status": "missing"}
    if opa.get("status") != "pass":
        blocking.append("policy unit tests")

    # ----------------------------------------------------------------- policies
    col_state: dict[tuple, str] = {}
    findings: dict[tuple, list[dict]] = {}
    for col in columns:
        c, e = col
        doc = load_json(res / f"conftest-{c}-{e}.json")
        status = load_json(res / f"status-{c}-{e}.json") or {}
        if doc is not None:
            col_state[col] = "ok"
            findings[col] = findings_from_conftest(doc)
        elif status.get("status") == "skipped":
            col_state[col] = "skipped:" + status.get("reason", "")
        else:
            col_state[col] = "error:" + status.get("reason", "no results")
            blocking.append(f"plan/policy evaluation failed for {c}/{e}")

    def cell(pid: str, meta: dict, col) -> str:
        c, e = col
        if meta["cloud"] not in ("all", c) or (meta.get("environments") and e not in meta["environments"]):
            return ICON["na"]
        st = col_state[col]
        if st.startswith("skipped"):
            return ICON["skipped"]
        if st.startswith("error"):
            return ICON["error"]
        kinds = {f["kind"] for f in findings[col] if f["id"] == pid}
        for k in ("fail", "warn", "waived"):
            if k in kinds:
                return ICON[k]
        return ICON["pass"]

    totals = {"fail": 0, "warn": 0, "waived": 0}
    for col, fs in findings.items():
        for f in fs:
            totals[f["kind"]] += 1
    if totals["fail"]:
        blocking.append(f"{totals['fail']} high-severity policy finding(s)")
    evaluated = [col for col in columns if col_state[col] == "ok"]
    passed = sum(
        1 for pid, meta in catalog.items() for col in evaluated if cell(pid, meta, col) == ICON["pass"]
    )

    # ------------------------------------------------------------------ render
    run_url = ""
    if os.getenv("GITHUB_RUN_ID"):
        run_url = f"{os.getenv('GITHUB_SERVER_URL')}/{os.getenv('GITHUB_REPOSITORY')}/actions/runs/{os.getenv('GITHUB_RUN_ID')}"
    sha = (os.getenv("PR_HEAD_SHA") or os.getenv("GITHUB_SHA") or "")[:7]
    head = "❌ **Blocked**" if blocking else "✅ **Compliant**"
    md = [
        MARKER,
        "## 🛡️ Terraform compliance report",
        f"{head} · commit `{sha}`" + (f" · [workflow run]({run_url})" if run_url else ""),
        "",
        f"**{passed}** checks passed · **{totals['fail']}** blocking · **{totals['warn']}** warnings · "
        f"**{totals['waived']}** waived · policy unit tests: {ICON['pass' if opa.get('status') == 'pass' else 'fail']}",
    ]
    if blocking:
        md += ["", "**Why this PR is blocked:**", *[f"- {b}" for b in dict.fromkeys(blocking)]]

    md += ["", "### 1. `terraform fmt` / `init` / `validate`", "",
           "| Root | fmt | init | validate | Notes |", "|---|:-:|:-:|:-:|---|", *validate_rows]

    md += ["", "### 2. OPA policy results", "",
           "Evaluated against the **full planned state** of each environment, so module defaults are covered too. "
           f"Legend: {ICON['pass']} pass · {ICON['fail']} blocking · {ICON['warn']} warning · {ICON['waived']} waived · "
           f"{ICON['na']} not applicable · {ICON['skipped']} skipped · {ICON['error']} could not evaluate", ""]
    md.append("| Policy | Sev | Control | " + " | ".join(f"{c}/{e}" for c, e in columns) + " |")
    md.append("|---|---|---|" + "|".join(":-:" for _ in columns) + "|")
    for pid, meta in catalog.items():
        sev = "🔴 high" if meta["severity"] == "high" else "🟡 med"
        md.append(f"| `{pid}` | {sev} | {meta['title']} | " + " | ".join(cell(pid, meta, col) for col in columns) + " |")

    skipped = [(col, s.split(":", 1)[1]) for col, s in col_state.items() if not s == "ok"]
    if skipped:
        md += ["", "**Not evaluated:**", *[f"- `{c}/{e}`: {why}" for (c, e), why in skipped]]

    all_findings = [(col, f) for col, fs in findings.items() for f in fs]
    if all_findings:
        md += ["", "### 3. Findings", ""]
        order = {"fail": 0, "warn": 1, "waived": 2}
        for (c, e), f in sorted(all_findings, key=lambda x: (order[x[1]["kind"]], x[1]["id"], x[0])):
            controls = "; ".join(f.get("controls") or [])
            md.append(f"- {ICON[f['kind']]} **`{f['id']}`** `{c}/{e}` · `{f['resource']}`  \n"
                      f"  {f['message']}  \n  <sub>{controls}</sub>")

    md += ["", "<details><summary>How to fix, waive, or run this locally</summary>", "",
           "- **Fix**: change the Terraform so the rule passes; policy logic lives in `policy/terraform/*.rego`.",
           "- **Waive** (time-boxed, reviewed): add an entry to `policy/data/waivers.yaml` with owner, reason and "
           "expiry. The finding stays visible as 🟦 and blocks again after the expiry date.",
           "- **Run locally**: `scripts/policy-check.sh gcp staging` (needs terraform, conftest; AWS needs credentials).",
           "- **Mapping**: control names come from `policy/data/catalog.yaml`. They show which control a check "
           "supports; passing them does not by itself make you CIS-certified or SOC 2 compliant.",
           "</details>"]

    text = "\n".join(md) + "\n"
    if a.out:
        Path(a.out).write_text(text)
    else:
        sys.stdout.write(text)
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
