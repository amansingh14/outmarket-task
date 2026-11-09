#!/usr/bin/env bash
# Terraform wrapper for one stack on one cloud, with remote state.
#
#   scripts/tf.sh <aws|gcp> <nonprod|preprod|production> <init|plan|apply|output|destroy> [extra terraform args]
#
# Required env:
#   aws: TF_STATE_BUCKET_AWS, AWS_REGION              (+ AWS credentials)
#   gcp: TF_STATE_BUCKET_GCP, GCP_REGION, GCP_PROJECT_ID (+ GCP credentials)
# State keys: idea-board/<stack>/terraform.tfstate (S3) and prefix idea-board/<stack> (GCS).
set -euo pipefail

CLOUD=${1:?cloud}; STACK=${2:?stack}; ACTION=${3:?action}; shift 3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AI="${DEVOPS_AI:-devops-ai}"
command -v "$AI" >/dev/null || AI="$ROOT/.venv/bin/devops-ai"

PROFILE=$("$AI" delivery infra --stack "$STACK" | sed -n 's/^profile=//p')
[ -n "$PROFILE" ] || { echo "unknown stack $STACK" >&2; exit 2; }
BUILD="$ROOT/build/$STACK"
mkdir -p "$BUILD"
"$AI" --summary /dev/null render --env "$PROFILE" --cloud "$CLOUD" --out-dir "$BUILD" >/dev/null

TF="$ROOT/infra/terraform/envs/$CLOUD"
VARS=(-var-file="$BUILD/$PROFILE.$CLOUD.auto.tfvars.json")
case "$CLOUD" in
  aws)
    : "${TF_STATE_BUCKET_AWS:?set TF_STATE_BUCKET_AWS}" "${AWS_REGION:?set AWS_REGION}"
    BACKEND=(-backend-config="bucket=$TF_STATE_BUCKET_AWS" -backend-config="key=idea-board/$STACK/terraform.tfstate"
             -backend-config="region=$AWS_REGION" -backend-config="encrypt=true" -backend-config="use_lockfile=true")
    VARS+=(-var "region=$AWS_REGION")
    ;;
  gcp)
    : "${TF_STATE_BUCKET_GCP:?set TF_STATE_BUCKET_GCP}" "${GCP_REGION:?set GCP_REGION}" "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}"
    BACKEND=(-backend-config="bucket=$TF_STATE_BUCKET_GCP" -backend-config="prefix=idea-board/$STACK")
    VARS+=(-var "region=$GCP_REGION" -var "project_id=$GCP_PROJECT_ID")
    ;;
  *) echo "cloud must be aws or gcp" >&2; exit 2 ;;
esac

terraform -chdir="$TF" init -input=false -reconfigure -no-color "${BACKEND[@]}" >&2

PLAN="$BUILD/$CLOUD.tfplan"
case "$ACTION" in
  init) ;;
  plan)
    terraform -chdir="$TF" plan -input=false -no-color "${VARS[@]}" -out="$PLAN" "$@"
    terraform -chdir="$TF" show -json "$PLAN" > "$BUILD/$CLOUD.plan.json"
    ;;
  apply)
    if [ -f "$PLAN" ]; then
      terraform -chdir="$TF" apply -input=false -no-color "$PLAN"   # exactly what was reviewed
    else
      echo "no saved plan at $PLAN; run plan first" >&2; exit 2
    fi
    ;;
  output) terraform -chdir="$TF" output "$@" ;;
  destroy) terraform -chdir="$TF" destroy -input=false "${VARS[@]}" "$@" ;;
  *) echo "unknown action $ACTION" >&2; exit 2 ;;
esac
