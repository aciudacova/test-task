#!/usr/bin/env bash
# Creates the S3 bucket holding Terraform state and writes backend.hcl for `terraform init`.
set -euo pipefail

REGION="${REGION:-eu-west-1}"
BACKEND_FILE="$(dirname "$0")/backend.hcl"

if [[ -f "$BACKEND_FILE" ]]; then
  BUCKET="$(awk -F'"' '/bucket/ {print $2}' "$BACKEND_FILE")"
  echo "Reusing bucket from backend.hcl: $BUCKET"
else
  # Random suffix keeps the globally-unique name from encoding the AWS account ID.
  BUCKET="startup-eks-tfstate-$(openssl rand -hex 4)"
  echo "Creating S3 bucket: $BUCKET"
fi

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

cat >"$BACKEND_FILE" <<EOF
bucket = "$BUCKET"
EOF

echo "Wrote $BACKEND_FILE"
echo "Next: terraform init -backend-config=backend.hcl"
