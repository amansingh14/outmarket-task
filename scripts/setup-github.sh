#!/usr/bin/env bash
# One-time GitHub setup for the branching model in config/deployments.yaml.
#
#   scripts/setup-github.sh [approver-login]
#
# Idempotent. Creates the environment branches, makes `development` the default branch,
# creates GitHub Environments (approvals on preprod/production), protects the branches and
# lets Actions open promotion PRs.
#
# Env overrides: BASE_BRANCH (default main), REQUIRED_APPROVALS (default 0: a solo maintainer
# cannot approve their own PRs; set 1+ for teams).
#
# Note: required reviewers on environments and branch protection on PRIVATE repos need a paid
# GitHub plan (Pro/Team/Enterprise). On a free private repo those calls fail and are reported.
set -uo pipefail

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
APPROVER=${1:-$(gh api user -q .login)}
APPROVER_ID=$(gh api "users/$APPROVER" -q .id)
BASE=${BASE_BRANCH:-main}
APPROVALS=${REQUIRED_APPROVALS:-0}
BRANCHES=(development staging qa preprod production)
FAILED=()

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; FAILED+=("$*"); }

echo "Repository: $REPO   approver: $APPROVER   base: $BASE"

echo "1. Environment branches"
SHA=$(gh api "repos/$REPO/git/ref/heads/$BASE" -q .object.sha)
for b in "${BRANCHES[@]}"; do
  if gh api "repos/$REPO/git/ref/heads/$b" >/dev/null 2>&1; then ok "$b exists"
  elif gh api "repos/$REPO/git/refs" -f "ref=refs/heads/$b" -f "sha=$SHA" >/dev/null; then ok "$b created from $BASE"
  else warn "could not create $b"; fi
done

echo "2. Default branch -> development (feature PRs target it by default)"
gh api -X PATCH "repos/$REPO" -f default_branch=development >/dev/null && ok "default branch is development" \
  || warn "could not set default branch"

echo "3. Let Actions open promotion PRs"
gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true >/dev/null \
  && ok "workflows may create pull requests" || warn "could not change Actions workflow permissions"

echo "4. GitHub Environments"
# Deploys come from workflow_run, whose ref is the default branch, so per-branch environment
# rules would block them. "protected branches only" still prevents deploying from a feature branch.
for env in development staging qa preprod production infra-nonprod infra-preprod infra-production; do
  case "$env" in
    preprod|production|infra-preprod|infra-production)
      body=$(jq -n --argjson id "$APPROVER_ID" \
        '{wait_timer: 0, prevent_self_review: false, reviewers: [{type: "User", id: $id}],
          deployment_branch_policy: {protected_branches: true, custom_branch_policies: false}}')
      label="requires approval by $APPROVER" ;;
    *)
      body='{"deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}}'
      label="auto-deploy" ;;
  esac
  if echo "$body" | gh api -X PUT "repos/$REPO/environments/$env" --input - >/dev/null 2>/tmp/env.err; then
    ok "$env ($label)"
  else
    # Retry without reviewers / branch policy (free private repos reject them).
    if gh api -X PUT "repos/$REPO/environments/$env" >/dev/null 2>&1; then
      warn "$env created WITHOUT protection rules ($(head -c 120 /tmp/env.err)); needs a public repo or paid plan"
    else
      warn "could not create environment $env"
    fi
  fi
done

echo "5. Branch protection (PR required, CI gate + compliance report must pass, no force-push)"
for b in "${BRANCHES[@]}"; do
  body=$(jq -n --argjson n "$APPROVALS" '{
    required_status_checks: {strict: false, contexts: ["gate", "report"]},
    enforce_admins: false,
    required_pull_request_reviews: {required_approving_review_count: $n, dismiss_stale_reviews: true},
    restrictions: null,
    allow_force_pushes: false,
    allow_deletions: false,
    required_linear_history: false
  }')
  if echo "$body" | gh api -X PUT "repos/$REPO/branches/$b/protection" --input - >/dev/null 2>/tmp/bp.err; then
    ok "$b protected"
  else
    warn "$b not protected: $(head -c 160 /tmp/bp.err)"
  fi
done

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "Done. Next: configure cloud variables/secrets (docs/delivery.md#cloud-setup)."
else
  echo "Done with ${#FAILED[@]} warning(s); see above."
fi
