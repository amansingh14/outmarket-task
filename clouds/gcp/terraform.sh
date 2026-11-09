# Sourced by scripts/tf.sh. Inputs: STACK. Must set BACKEND=() and append cloud vars to VARS.
: "${TF_STATE_BUCKET_GCP:?set TF_STATE_BUCKET_GCP}" "${GCP_REGION:?set GCP_REGION}" "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}"
BACKEND=(
  -backend-config="bucket=$TF_STATE_BUCKET_GCP"
  -backend-config="prefix=idea-board/$STACK"
)
VARS+=(-var "region=$GCP_REGION" -var "project_id=$GCP_PROJECT_ID" -var "project_number=${GCP_PROJECT_NUMBER:?set GCP_PROJECT_NUMBER}")
