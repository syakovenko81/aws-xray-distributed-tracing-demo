#!/usr/bin/env bash
set -euo pipefail

region="${1:-us-east-1}"
layer_arn="${2:-arn:aws:lambda:us-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:32}"

terraform -chdir=terraform init
terraform -chdir=terraform apply \
  -var="region=${region}" \
  -var="adot_python_layer_arn=${layer_arn}"

terraform -chdir=terraform output api_endpoint
