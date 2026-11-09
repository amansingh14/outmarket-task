#!/usr/bin/env bash
# Deploy one environment to one cloud. The Deploy workflow runs exactly this script.
#
#   scripts/deploy.sh <environment> <cloud>
#
# Env: IMAGE_OWNER, BACKEND_TAG, FRONTEND_TAG (required) · GHCR_PULL_TOKEN (optional) ·
#      RESULT_FILE (optional, JSON summary) · ANTHROPIC_API_KEY (optional, AI health verdict).
#
# Target resolution:
#   default            Terraform outputs of the environment's stack (scripts/tf.sh) give the cluster
#                      (kubeconfig_command) and database; the admin password comes from the cloud's
#                      secret store (clouds/<cloud>/db-admin-url.sh).
#   DEPLOY_TARGET=env  use the current kube context plus DB_HOST / DB_PORT / ADMIN_DATABASE_URL from
#                      the environment (local kind cluster, tests). EXTRA_HELM_ARGS and HEALTH_URL
#                      tweak the release for clusters without cloud load balancers.
#
# Exit: 0 deployed and healthy · 1 failed health check (rolled back when possible) · 2 usage/config.
set -uo pipefail

ENV_NAME=${1:?usage: deploy.sh <environment> <cloud>}
CLOUD=${2:?usage: deploy.sh <environment> <cloud>}
: "${IMAGE_OWNER:?}" "${BACKEND_TAG:?}" "${FRONTEND_TAG:?}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AI="${DEVOPS_AI:-devops-ai}"
command -v "$AI" >/dev/null || AI="$ROOT/.venv/bin/devops-ai"
RELEASE=idea-board
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n▶ %s\n' "$*"; }
mask() { [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$1" ] && echo "::add-mask::$1"; return 0; }
result() {  # status verdict url
  [ -n "${RESULT_FILE:-}" ] || return 0
  jq -n --arg c "$CLOUD" --arg s "$1" --arg v "$2" --arg u "$3" --arg b "$BACKEND_TAG" --arg f "$FRONTEND_TAG" \
    '{cloud: $c, status: $s, verdict: $v, url: $u, backend: $b, frontend: $f}' > "$RESULT_FILE"
}

# ---------------------------------------------------------------- resolve
"$AI" delivery resolve --environment "$ENV_NAME" > "$WORK/resolve.txt" || exit 2
MATRIX=$(sed -n 's/^matrix=//p' "$WORK/resolve.txt")
ENTRY=$(jq -c --arg c "$CLOUD" '.include[] | select(.cloud == $c)' <<<"$MATRIX")
[ -n "$ENTRY" ] || { echo "environment $ENV_NAME does not deploy to $CLOUD (config/deployments.yaml)" >&2; exit 2; }
STACK=$(jq -r .stack <<<"$ENTRY"); NS=$(jq -r .namespace <<<"$ENTRY")
echo "environment=$ENV_NAME cloud=$CLOUD stack=$STACK namespace=$NS backend=$BACKEND_TAG frontend=$FRONTEND_TAG"

# ----------------------------------------------------------- cluster + DB
if [ "${DEPLOY_TARGET:-terraform}" = env ]; then
  : "${DB_HOST:?}" "${ADMIN_DATABASE_URL:?}"
  DB_PORT=${DB_PORT:-5432}
  ADMIN="$ADMIN_DATABASE_URL"
else
  log "Stack outputs ($STACK on $CLOUD)"
  if ! "$ROOT/scripts/tf.sh" "$CLOUD" "$STACK" output -json > "$WORK/tf.json" 2>"$WORK/tf.err" \
     || [ "$(jq -r '.cluster_name.value // empty' "$WORK/tf.json")" = "" ]; then
    echo "::error::stack '$STACK' is not provisioned on $CLOUD yet. Run the Infrastructure workflow for it, then re-run this deploy." >&2
    tail -5 "$WORK/tf.err" >&2
    result failed "" ""; exit 2
  fi
  DB_HOST=$(jq -r .database_host.value "$WORK/tf.json"); DB_PORT=$(jq -r .database_port.value "$WORK/tf.json")
  eval "$(jq -r .kubeconfig_command.value "$WORK/tf.json")" >/dev/null
  ADMIN=$("$ROOT/clouds/$CLOUD/db-admin-url.sh" "$WORK/tf.json") || { echo "::error::could not read DB admin credentials" >&2; exit 2; }
fi
mask "$ADMIN"; mask "$(python3 -c 'import sys,urllib.parse as u; print(u.urlsplit(sys.argv[1]).password or "")' "$ADMIN")"
kubectl version -o json 2>/dev/null | jq -r '"cluster: " + .serverVersion.gitVersion'

log "Namespace and admin secret"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Only the provisioning hook reads this; the app gets its own least-privilege login.
kubectl -n "$NS" create secret generic idea-board-db-admin --from-literal=ADMIN_DATABASE_URL="$ADMIN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
PULL=()
if [ -n "${GHCR_PULL_TOKEN:-}" ]; then
  kubectl -n "$NS" create secret docker-registry ghcr-pull --docker-server=ghcr.io \
    --docker-username="$IMAGE_OWNER" --docker-password="$GHCR_PULL_TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  PULL=(--set "image.pullSecrets[0]=ghcr-pull")
fi

frontend_url() {
  [ -n "${HEALTH_URL:-}" ] && { echo "$HEALTH_URL"; return; }
  local host
  host=$(kubectl -n "$NS" get svc "$RELEASE-frontend" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$host" ] && echo "http://$host"
}

log "Baseline of the running release (for the post-deploy comparison)"
"$AI" health-snapshot --namespace "$NS" --release "$RELEASE" --url "$(frontend_url)" --out "$WORK/baseline.json"

log "helm upgrade"
"$AI" delivery env-values --env "$ENV_NAME" --out "$WORK/values.yaml" >/dev/null
# shellcheck disable=SC2086
helm upgrade --install "$RELEASE" "$ROOT/deploy/helm/idea-board" -n "$NS" -f "$WORK/values.yaml" \
  --set image.owner="$IMAGE_OWNER" --set backend.image.tag="$BACKEND_TAG" --set frontend.image.tag="$FRONTEND_TAG" \
  --set database.host="$DB_HOST" --set database.port="$DB_PORT" --set environment="$ENV_NAME" \
  ${PULL[@]+"${PULL[@]}"} ${EXTRA_HELM_ARGS:-} --history-max 10 --wait --timeout 10m >"$WORK/helm.log" 2>&1
HELM_RC=$?  # no pipeline: a failure must not run in a subshell that fires the EXIT trap early
cat "$WORK/helm.log"
HELM_FAILED=""
[ "$HELM_RC" -ne 0 ] && HELM_FAILED=$(grep -m1 -iE "error|failed|timed out" "$WORK/helm.log" | cut -c1-300)

log "Public URL"
URL=""
SVC_TYPE=$(kubectl -n "$NS" get svc "$RELEASE-frontend" -o jsonpath='{.spec.type}' 2>/dev/null)
if [ -n "${HEALTH_URL:-}" ]; then
  URL=$HEALTH_URL
elif [ "$SVC_TYPE" = LoadBalancer ]; then
  for _ in $(seq 1 60); do URL=$(frontend_url) && [ -n "$URL" ] && break; sleep 5; done
fi
echo "${URL:-<no load balancer address>}"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "url=$URL" >> "$GITHUB_OUTPUT"

# A brand-new cloud load balancer answers before it routes reliably (GCP: 1-3 min of timeouts).
# Wait for 5 consecutive 200s (max ~4 min) so the health check judges the app, not LB warm-up.
# This only delays the probes; a release that never becomes reachable still fails them.
if [ -n "$URL" ] && [ -z "${HEALTH_URL:-}" ]; then
  log "Waiting for the load balancer to route"
  ok=0
  for _ in $(seq 1 80); do
    if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$URL/" || true)" = 200 ]; then ok=$((ok + 1)); else ok=0; fi
    [ "$ok" -ge 5 ] && break
    sleep 3
  done
  if [ "$ok" -ge 5 ]; then echo "routing"; else echo "still not routing reliably; the health check will judge it"; fi
fi

log "AI health check"
HC=(--namespace "$NS" --release "$RELEASE" --baseline "$WORK/baseline.json" --rollback --report "$WORK/health.json")
[ -n "$URL" ] && HC+=(--url "$URL")
[ -n "$HELM_FAILED" ] && HC+=(--helm-failed "$HELM_FAILED")
"$AI" health-check "${HC[@]}"
HEALTH_RC=$?
VERDICT=$(jq -r .verdict.verdict "$WORK/health.json" 2>/dev/null || echo unknown)

if [ "$HEALTH_RC" -eq 0 ] && [ "$HELM_RC" -eq 0 ]; then
  result deployed "$VERDICT" "$URL"
  echo "✅ $ENV_NAME on $CLOUD is live: ${URL:-(no public URL)}"
  exit 0
fi
result rolled_back "$VERDICT" "$URL"
echo "::error::$ENV_NAME on $CLOUD failed its health check and was rolled back (helm rc=$HELM_RC, verdict=$VERDICT)" >&2
exit 1
