#!/usr/bin/env bash
# Print the libpq admin URL for the stack's database. Arg: terraform output -json file.
# The master password lives only in AWS Secrets Manager (RDS-managed), never in Terraform state.
set -euo pipefail
OUT=${1:?terraform output json}
secret=$(jq -r .database_admin_secret.value "$OUT")
creds=$(aws secretsmanager get-secret-value --secret-id "$secret" --query SecretString --output text)
python3 - "$OUT" "$creds" <<'PY'
import json, sys, urllib.parse as u
out, creds = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
q = lambda s: u.quote(s, safe="")
print(f"postgresql://{q(creds['username'])}:{q(creds['password'])}@{out['database_host']['value']}:"
      f"{out['database_port']['value']}/{out['database_name']['value']}?sslmode=require")
PY
