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

echo "4. GitHub Environments (each deployable only from its own branch)"
# Deploys run from CI on the environment's own branch, so each environment is locked to it:
# nobody can deploy production from a feature branch, even with a manual run.
declare_env() {  # name branch needs_approval
  local name=$1 branch=$2 approval=$3 body label
  if [ "$approval" = yes ]; then
    body=$(jq -n --argjson id "$APPROVER_ID" '{wait_timer: 0, prevent_self_review: false,
      reviewers: [{type: "User", id: $id}],
      deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}')
    label="approval by $APPROVER, branch $branch only"
  else
    body='{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
    label="auto-deploy, branch $branch only"
  fi
  if echo "$body" | gh api -X PUT "repos/$REPO/environments/$name" --input - >/dev/null 2>/tmp/env.err; then
    gh api -X POST "repos/$REPO/environments/$name/deployment-branch-policies" -f name="$branch" -f type=branch \
      >/dev/null 2>&1 || true   # already present
    ok "$name ($label)"
  elif gh api -X PUT "repos/$REPO/environments/$name" >/dev/null 2>&1; then
    warn "$name created WITHOUT protection rules ($(head -c 120 /tmp/env.err)); needs a public repo or paid plan"
  else
    warn "could not create environment $name"
  fi
}
declare_env development development no
declare_env staging staging no
declare_env qa qa no
declare_env preprod preprod yes
declare_env production production yes
declare_env infra-nonprod development no
declare_env infra-preprod preprod yes
declare_env infra-production production yes

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
