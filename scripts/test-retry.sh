#!/usr/bin/env bash
set -euo pipefail

function_name="${1:-$(terraform -chdir=terraform output -raw lambda_b_name)}"
correlation_id="${2:-troubleshooting-async-$(date -u +%Y%m%d%H%M%S)}"
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(terraform -chdir=terraform output -raw deployment_region)}}"

aws --region "$region" lambda invoke \
  --function-name "$function_name" \
  --invocation-type Event \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"message\":\"async retry experiment\",\"correlation_id\":\"${correlation_id}\",\"simulate_error\":true}" \
  /tmp/lambda-troubleshooting-async-response.json

echo "Async invocation queued for ${function_name}; search Lambda B logs for correlation_id=${correlation_id}."
