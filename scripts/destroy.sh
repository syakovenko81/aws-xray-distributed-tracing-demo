#!/usr/bin/env bash
set -euo pipefail

table_name="$(terraform -chdir=terraform output -raw dynamodb_table_name 2>/dev/null || true)"
region="$(terraform -chdir=terraform output -raw deployment_region 2>/dev/null || true)"

if [[ -n "$table_name" && -n "$region" ]]; then
  echo "Deleting demo DynamoDB table ${table_name} before Terraform destroy..."
  aws --region "$region" dynamodb delete-table --table-name "$table_name" >/dev/null 2>&1 || true
  aws --region "$region" dynamodb wait table-not-exists --table-name "$table_name" || true
fi

terraform -chdir=terraform destroy "$@"
