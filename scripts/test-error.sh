#!/usr/bin/env bash
set -euo pipefail

endpoint="${1:-$(terraform -chdir=terraform output -raw api_endpoint)}"
correlation_id="${2:-demo-error-$(date -u +%Y%m%d%H%M%S)}"

curl -sS -X POST "$endpoint" \
  -H 'content-type: application/json' \
  -d "{\"message\":\"intentional failure\",\"correlation_id\":\"${correlation_id}\",\"simulate_error\":true}"
printf '\n'
