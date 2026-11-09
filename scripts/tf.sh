#!/usr/bin/env bash
# Terraform wrapper for one stack on one cloud, with remote state.
#
#   scripts/tf.sh <cloud> <stack> <init|plan|apply|output|destroy> [extra terraform args]
#
# Cloud specifics (state backend, provider variables) come from clouds/<cloud>/terraform.sh, so this
# script never names a cloud. Sizing comes from config/stacks/<stack>.yaml via `devops-ai render`.
set -euo pipefail

CLOUD=${1:?cloud}; STACK=${2:?stack}; ACTION=${3:?action}; shift 3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN="$ROOT/clouds/$CLOUD/terraform.sh"
[ -f "$PLUGIN" ] || { echo "no cloud plugin at clouds/$CLOUD" >&2; exit 2; }
AI="${DEVOPS_AI:-devops-ai}"
command -v "$AI" >/dev/null || AI="$ROOT/.venv/bin/devops-ai"

BUILD="$ROOT/build/$STACK"
mkdir -p "$BUILD"
"$AI" --summary /dev/null render --stack "$STACK" --cloud "$CLOUD" --out-dir "$BUILD" >/dev/null

TF="$ROOT/$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["terraform_root"])' "$ROOT/clouds/$CLOUD/cloud.yaml")"
VARS=(-var-file="$BUILD/$STACK.$CLOUD.auto.tfvars.json")
BACKEND=()
# shellcheck source=/dev/null
source "$PLUGIN"   # sets BACKEND, appends to VARS

terraform -chdir="$TF" init -input=false -reconfigure -no-color "${BACKEND[@]}" >&2

PLAN="$BUILD/$CLOUD.tfplan"
case "$ACTION" in
  init) ;;
  plan)
    terraform -chdir="$TF" plan -input=false -no-color "${VARS[@]}" -out="$PLAN" "$@"
    terraform -chdir="$TF" show -json "$PLAN" > "$BUILD/$CLOUD.plan.json"
    ;;
  apply)
    [ -f "$PLAN" ] || { echo "no saved plan at $PLAN; run plan first" >&2; exit 2; }
    terraform -chdir="$TF" apply -input=false -no-color "$PLAN"   # exactly what was reviewed
    ;;
  output) terraform -chdir="$TF" output "$@" ;;
  destroy) terraform -chdir="$TF" destroy -input=false "${VARS[@]}" "$@" ;;
  *) echo "unknown action $ACTION" >&2; exit 2 ;;
esac
