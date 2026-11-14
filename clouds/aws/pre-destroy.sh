#!/usr/bin/env bash
# Run by scripts/destroy.sh before it lifts deletion protection on a protected stack.
# Args: terraform output -json file, stack. Takes a manual RDS snapshot, which (unlike automated
# backups) survives the instance's deletion. Lifting protection also flips skip_final_snapshot,
# so without this the data would be gone.
set -euo pipefail
OUT=${1:?terraform output json}; STACK=${2:?stack}
host=$(jq -r '.database_host.value // empty' "$OUT")
[ -n "$host" ] || { echo "no database in state; no snapshot needed"; exit 0; }
db=${host%%.*} # <identifier>.<hash>.<region>.rds.amazonaws.com
snap="$db-predestroy-$(date -u +%Y%m%d%H%M%S)"
echo "creating RDS snapshot $snap of $db"
aws rds create-db-snapshot --db-instance-identifier "$db" --db-snapshot-identifier "$snap" \
  --tags Key=stack,Value="$STACK" Key=reason,Value=pre-destroy >/dev/null
aws rds wait db-snapshot-available --db-snapshot-identifier "$snap"
echo "snapshot $snap available (restore with: aws rds restore-db-instance-from-db-snapshot)"
echo "### 💾 final RDS snapshot \`$snap\` retained" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
