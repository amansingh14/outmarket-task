#!/usr/bin/env bash
# Print the libpq admin URL for the stack's database. Arg: terraform output -json file.
# The password was written to Secret Manager with a write-only argument, never to Terraform state.
set -euo pipefail
OUT=${1:?terraform output json}
secret=$(jq -r .database_admin_secret.value "$OUT")
password=$(gcloud secrets versions access latest --secret="$secret" --project="${GCP_PROJECT_ID:?}")
python3 - "$OUT" "$password" <<'PY'
import json, sys, urllib.parse as u
out, password = json.load(open(sys.argv[1])), sys.argv[2]
q = lambda s: u.quote(s, safe="")
print(f"postgresql://{q(out['database_admin_username']['value'])}:{q(password)}@{out['database_host']['value']}:"
      f"{out['database_port']['value']}/{out['database_name']['value']}?sslmode=require")
PY
