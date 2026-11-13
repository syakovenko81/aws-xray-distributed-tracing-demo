#!/usr/bin/env bash
set -euo pipefail

endpoint="${1:-$(terraform -chdir=terraform output -raw api_endpoint)}"
correlation_id="${2:-troubleshooting-latency-$(date -u +%Y%m%d%H%M%S)}"
delay_ms="${3:-2000}"

echo "Baseline request: ${correlation_id}-baseline"
curl --fail-with-body -sS -X POST "$endpoint" \
  -H 'content-type: application/json' \
  -d "{\"message\":\"latency baseline\",\"correlation_id\":\"${correlation_id}-baseline\"}"
printf '\n'

echo "Controlled delay request: ${correlation_id}-delayed (${delay_ms} ms)"
curl -sS -X POST "$endpoint" \
  -H 'content-type: application/json' \
  -d "{\"message\":\"latency experiment\",\"correlation_id\":\"${correlation_id}-delayed\",\"troubleshooting\":{\"delay_ms\":${delay_ms}}}"
printf '\n'
