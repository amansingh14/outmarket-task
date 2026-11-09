#!/usr/bin/env bash
# Run the same Terraform compliance check the PR workflow runs, locally.
#
#   scripts/policy-check.sh <aws|gcp> <environment>      e.g. scripts/policy-check.sh gcp staging
#
# Plans the FULL desired state against an empty local state (no remote state needed),
# then evaluates the OPA policies with conftest.
#   GCP: works without credentials (a dummy token is used if none is set).
#   AWS: needs read-only AWS credentials (the EKS/VPC modules query STS and AZs at plan time).
set -euo pipefail

CLOUD=${1:?usage: policy-check.sh <aws|gcp> <environment>}
ENV=${2:?usage: policy-check.sh <aws|gcp> <environment>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for bin in terraform conftest; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 2; }
done

AI="${ROOT}/.venv/bin/devops-ai"
[ -x "$AI" ] || AI="devops-ai"
"$AI" --summary /dev/null render --env "$ENV" --cloud "$CLOUD" --out-dir "$WORK" >/dev/null

# Work on a copy so the local backend override never touches the repo.
cp -R "$ROOT/infra" "$WORK/infra"
TF="$WORK/infra/terraform/envs/$CLOUD"
rm -rf "$TF/.terraform"
printf 'terraform {\n  backend "local" {}\n}\n' > "$TF/backend_override.tf"

VARS=(-var-file="$WORK/$ENV.$CLOUD.auto.tfvars.json")
if [ "$CLOUD" = "gcp" ]; then
  VARS+=(-var "region=${GCP_REGION:-us-central1}" -var "project_id=${GCP_PROJECT_ID:-policy-check-placeholder}")
  if [ -z "${GOOGLE_OAUTH_ACCESS_TOKEN:-}${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
    export GOOGLE_OAUTH_ACCESS_TOKEN=offline-plan-dummy-token
  fi
else
  VARS+=(-var "region=${AWS_REGION:-us-east-1}")
fi

terraform -chdir="$TF" init -input=false -no-color >/dev/null
terraform -chdir="$TF" plan -input=false -lock=false -no-color "${VARS[@]}" -out=tfplan >"$WORK/plan.log" \
  || { tail -30 "$WORK/plan.log"; exit 1; }
terraform -chdir="$TF" show -json tfplan >"$WORK/plan.json"

conftest test "$WORK/plan.json" --policy "$ROOT/policy/terraform" --data "$ROOT/policy/data" \
  --namespace terraform.common --namespace "terraform.$CLOUD"
