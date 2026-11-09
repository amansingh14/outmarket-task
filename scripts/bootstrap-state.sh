#!/usr/bin/env bash
# One-time creation of the Terraform state buckets (run with admin credentials).
#
#   scripts/bootstrap-state.sh aws <bucket-name> <region>
#   scripts/bootstrap-state.sh gcp <bucket-name> <region> <project-id>
#
# Buckets are versioned (state history / recovery), encrypted and never public.
set -euo pipefail
CLOUD=${1:?aws|gcp}; BUCKET=${2:?bucket}; REGION=${3:?region}

case "$CLOUD" in
  aws)
    if [ "$REGION" = us-east-1 ]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
    fi
    aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
    aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    ;;
  gcp)
    PROJECT=${4:?project-id}
    gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT" --location "$REGION" \
      --uniform-bucket-level-access --public-access-prevention
    gcloud storage buckets update "gs://$BUCKET" --versioning
    ;;
  *) echo "cloud must be aws or gcp" >&2; exit 2 ;;
esac
echo "state bucket ready: $CLOUD $BUCKET"
