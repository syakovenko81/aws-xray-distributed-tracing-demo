#!/usr/bin/env bash
set -euo pipefail

endpoint="${1:-$(terraform -chdir=terraform output -raw api_endpoint)}"
correlation_id="${2:-demo-success-$(date -u +%Y%m%d%H%M%S)}"

curl --fail-with-body -sS -X POST "$endpoint" \
  -H 'content-type: application/json' \
  -d "{\"message\":\"hello from the X-Ray demo\",\"correlation_id\":\"${correlation_id}\"}"
printf '\n'
