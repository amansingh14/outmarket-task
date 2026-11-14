#!/usr/bin/env bash
# Tear down one stack on one cloud with Terraform. The Destroy workflow runs exactly this script.
#
#   scripts/destroy.sh <cloud> <stack> plan    destroy plan -> build/<stack>/<cloud>.tfplan, plus the
#                                              list of resources it deletes (what the reviewer approves)
#   scripts/destroy.sh <cloud> <stack> apply   1. drain the cluster: uninstall Helm releases, delete
#                                                 LoadBalancer Services and PVCs, so the cloud load
#                                                 balancers and disks Kubernetes created (not in
#                                                 Terraform state) are removed and don't block the VPC
#                                              2. if the stack has deletion_protection: run the cloud's
#                                                 pre-destroy hook (final DB snapshot), lift protection,
#                                                 re-plan, and refuse if the plan differs from the review
#                                              3. apply the reviewed destroy plan; retry what is left
#                                                 (cloud APIs release dependencies with a delay)
#                                              4. verify the state is empty
#
# Needs the same environment as scripts/tf.sh (state bucket, region, project variables), plus
# kubectl and helm for the drain. The state bucket itself is never touched.
set -euo pipefail

CLOUD=${1:?usage: destroy.sh <cloud> <stack> <plan|apply>}
STACK=${2:?usage: destroy.sh <cloud> <stack> <plan|apply>}
ACTION=${3:?usage: destroy.sh <cloud> <stack> <plan|apply>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TF="$ROOT/scripts/tf.sh"
BUILD="$ROOT/build/$STACK"
PLAN="$BUILD/$CLOUD.tfplan"
PLAN_JSON="$BUILD/$CLOUD.plan.json"
REVIEWED="$BUILD/$CLOUD.destroy-reviewed.txt"
TFVARS="$BUILD/$STACK.$CLOUD.auto.tfvars.json"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n▶ %s\n' "$*"; }
die() { echo "::error::$*" >&2; exit 1; }
summary() { tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
# Addresses a saved plan deletes, sorted (comparable between plans).
deletes() { jq -r '[.resource_changes[]? | select(.change.actions | index("delete")) | .address] | sort | .[]' "$PLAN_JSON"; }
plan_destroy() { "$TF" "$CLOUD" "$STACK" plan -destroy >"$WORK/plan.log" 2>&1 || { cat "$WORK/plan.log"; return 1; }; tail -3 "$WORK/plan.log"; }
protected() { [ "$(jq -r '.deletion_protection // false' "$TFVARS")" = true ]; }

drain() {
  log "Drain the cluster (cloud resources Kubernetes created outside Terraform)"
  if ! "$TF" "$CLOUD" "$STACK" output -json >"$WORK/tf.json" 2>/dev/null \
     || [ -z "$(jq -r '.cluster_name.value // empty' "$WORK/tf.json")" ]; then
    echo "no cluster in state; nothing to drain"; return 0
  fi
  if ! eval "$(jq -r .kubeconfig_command.value "$WORK/tf.json")" >/dev/null 2>&1 || ! kubectl get ns >/dev/null 2>&1; then
    echo "::warning::$CLOUD cluster unreachable; load balancers/disks created by Kubernetes may be left behind"
    return 0
  fi

  helm list -A -o json 2>/dev/null | jq -r '.[] | "\(.namespace) \(.name)"' | while read -r ns rel; do
    echo "helm uninstall $rel -n $ns"
    helm uninstall "$rel" -n "$ns" --wait --timeout 10m || echo "::warning::could not uninstall $ns/$rel"
  done

  # The Service finalizer makes `kubectl delete` wait until the cloud load balancer is gone.
  kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        echo "delete LoadBalancer service $ns/$name"
        kubectl delete svc "$name" -n "$ns" --timeout=10m || echo "::warning::could not delete service $ns/$name"
      done
  kubectl delete ingress --all -A --timeout=10m 2>/dev/null || true

  # Dynamically provisioned disks (EBS / Persistent Disk) are deleted with their PVCs.
  kubectl get pvc -A -o json | jq -r '.items[] | select(.metadata.namespace | test("^(kube-|gke-|gmp-|amazon-)") | not)
                                      | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        echo "delete pvc $ns/$name"
        kubectl delete pvc "$name" -n "$ns" --timeout=5m || echo "::warning::could not delete pvc $ns/$name"
      done
  for _ in $(seq 1 30); do
    left=$(kubectl get pv -o json | jq '[.items[] | select(.spec.persistentVolumeReclaimPolicy == "Delete")] | length')
    [ "$left" = 0 ] && break
    echo "waiting for $left persistent volume(s) to be released"; sleep 10
  done
}

case "$ACTION" in
  plan)
    log "Destroy plan: $STACK on $CLOUD"
    plan_destroy
    deletes >"$REVIEWED"
    n=$(grep -c . "$REVIEWED" || true)
    {
      if [ "$n" = 0 ]; then
        echo "### ✅ \`$STACK\` on \`$CLOUD\`: nothing in Terraform state, nothing to destroy"
      else
        echo "### 🧨 \`$STACK\` on \`$CLOUD\`: destroy deletes $n resources"
        protected && echo "> [!WARNING]
> deletion_protection is on: the apply lifts it first$( [ -x "$ROOT/clouds/$CLOUD/pre-destroy.sh" ] && echo " after a final database snapshot" )."
        # shellcheck disable=SC2016 # literal backticks: markdown code spans
        echo "<details><summary>resources</summary>"; echo; sed 's/^/- `/; s/$/`/' "$REVIEWED"; echo; echo "</details>"
      fi
    } | summary
    ;;

  apply)
    [ -f "$PLAN" ] && [ -f "$REVIEWED" ] || die "no reviewed destroy plan in $BUILD; run '$0 $CLOUD $STACK plan' first"
    if [ ! -s "$REVIEWED" ]; then echo "nothing to destroy for $STACK on $CLOUD"; exit 0; fi

    drain

    if protected; then
      if [ -x "$ROOT/clouds/$CLOUD/pre-destroy.sh" ]; then
        log "Pre-destroy hook (clouds/$CLOUD/pre-destroy.sh)"
        "$TF" "$CLOUD" "$STACK" output -json >"$WORK/tf.json"
        "$ROOT/clouds/$CLOUD/pre-destroy.sh" "$WORK/tf.json" "$STACK"
      else
        echo "::warning::$CLOUD has no pre-destroy hook: the database is deleted without a retained final backup"
      fi
      log "Lift deletion protection"
      "$TF" "$CLOUD" "$STACK" plan -var deletion_protection=false
      "$TF" "$CLOUD" "$STACK" apply
      log "Re-plan the destroy (state changed) and compare with the reviewed plan"
      plan_destroy
      deletes | diff "$REVIEWED" - || die "destroy plan differs from the reviewed one; re-run the plan and review it again"
    fi

    for attempt in 1 2 3; do
      log "terraform apply (destroy), attempt $attempt"
      if "$TF" "$CLOUD" "$STACK" apply; then break; fi
      [ "$attempt" = 3 ] && die "destroy of $STACK on $CLOUD still failing after 3 attempts; see the errors above"
      echo "waiting 2 min for the cloud to release dependencies, then retrying what is left"
      sleep 120
      plan_destroy
      extra=$(deletes | comm -13 "$REVIEWED" - || true)
      [ -z "$extra" ] || die "the retry would delete resources that were not reviewed: $extra"
    done

    log "Verify"
    plan_destroy
    left=$(deletes)
    [ -z "$left" ] || die "resources still in state after destroy: $left"
    echo "### ✅ \`$STACK\` on \`$CLOUD\` destroyed ($(grep -c . "$REVIEWED") resources)" | summary
    ;;

  *) echo "unknown action $ACTION (plan|apply)" >&2; exit 2 ;;
esac
