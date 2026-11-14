# Sourced by scripts/policy-check.sh before a compliance plan (empty local state).
# Must set the cloud variables the root needs, and return 3 if a plan is impossible.
VARS+=(-var "region=${AWS_REGION:-us-east-1}")
if [ -z "${AWS_ACCESS_KEY_ID:-}${AWS_PROFILE:-}${AWS_WEB_IDENTITY_TOKEN_FILE:-}${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]; then
  echo "AWS credentials required: the EKS and VPC modules query STS and availability zones at plan time" >&2
  return 3
fi
