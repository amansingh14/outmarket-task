#!/usr/bin/env bash
# Terraform compliance check for one cloud + stack. The PR workflow runs exactly this script.
#
#   scripts/policy-check.sh <cloud> <stack> [--json-out results.json] [--plan-out plan.json]
#
# Plans the FULL desired state against an empty local state (no remote state or write access
# needed), then evaluates the OPA policies with conftest.
#
# Exit codes: 0 compliant (warnings allowed) · 1 blocking findings · 3 cannot plan here
# (e.g. missing cloud credentials; see clouds/<cloud>/plan-env.sh) · 4 terraform plan failed.
set -uo pipefail

CLOUD=${1:?usage: policy-check.sh <cloud> <stack> [--json-out FILE] [--plan-out FILE]}
STACK=${2:?usage: policy-check.sh <cloud> <stack> [--json-out FILE] [--plan-out FILE]}
shift 2
JSON_OUT="" PLAN_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json-out) JSON_OUT=$2; shift 2 ;;
    --plan-out) PLAN_OUT=$2; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$ROOT/clouds/$CLOUD/plan-env.sh" ] || { echo "no cloud plugin clouds/$CLOUD" >&2; exit 2; }
for bin in terraform conftest; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 2; }
done
AI="${DEVOPS_AI:-devops-ai}"
command -v "$AI" >/dev/null || AI="$ROOT/.venv/bin/devops-ai"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$AI" --summary /dev/null render --stack "$STACK" --cloud "$CLOUD" --out-dir "$WORK" >/dev/null || exit 2

# Plan a copy so the local-backend override never touches the repository.
cp -R "$ROOT/infra" "$WORK/infra"
TF="$WORK/infra/terraform/envs/$CLOUD"
rm -rf "$TF/.terraform"
printf 'terraform {\n  backend "local" {}\n}\n' > "$TF/backend_override.tf"

VARS=(-var-file="$WORK/$STACK.$CLOUD.auto.tfvars.json")
# shellcheck source=/dev/null
source "$ROOT/clouds/$CLOUD/plan-env.sh" || exit 3

if ! terraform -chdir="$TF" init -input=false -no-color >"$WORK/plan.log" 2>&1 \
   || ! terraform -chdir="$TF" plan -input=false -lock=false -no-color "${VARS[@]}" -out=tfplan >>"$WORK/plan.log" 2>&1; then
  tail -30 "$WORK/plan.log" >&2
  exit 4
fi
terraform -chdir="$TF" show -json tfplan >"$WORK/plan.json"
[ -n "$PLAN_OUT" ] && cp "$WORK/plan.json" "$PLAN_OUT"

POLICY=(--policy "$ROOT/policy/terraform" --data "$ROOT/policy/data" --namespace terraform.common --namespace "terraform.$CLOUD")
[ -n "$JSON_OUT" ] && conftest test "$WORK/plan.json" "${POLICY[@]}" -o json >"$JSON_OUT" 2>/dev/null
conftest test "$WORK/plan.json" "${POLICY[@]}" --no-color
