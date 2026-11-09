# Sourced by scripts/policy-check.sh before a compliance plan (empty local state).
VARS+=(-var "region=${GCP_REGION:-us-central1}" -var "project_id=${GCP_PROJECT_ID:-policy-check-placeholder}"
      -var "project_number=${GCP_PROJECT_NUMBER:-000000000000}")
# The GCP root has no data sources, so planning against empty state needs no real API access.
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]; then
  export GOOGLE_OAUTH_ACCESS_TOKEN=offline-plan-dummy-token
fi
