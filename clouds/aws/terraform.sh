# Sourced by scripts/tf.sh. Inputs: STACK. Must set BACKEND=() and append cloud vars to VARS.
: "${TF_STATE_BUCKET_AWS:?set TF_STATE_BUCKET_AWS}" "${AWS_REGION:?set AWS_REGION}"
BACKEND=(
  -backend-config="bucket=$TF_STATE_BUCKET_AWS"
  -backend-config="key=idea-board/$STACK/terraform.tfstate"
  -backend-config="region=$AWS_REGION"
  -backend-config="encrypt=true"
  -backend-config="use_lockfile=true"
)
VARS+=(-var "region=$AWS_REGION")
