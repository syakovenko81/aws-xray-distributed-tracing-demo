#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_ACCOUNT_ID="661200526584"
readonly EXPECTED_REGION="us-east-1"
readonly PROJECT_NAME="${AWS_CONFIG_POC_PROJECT_NAME:-aws-config-poc}"
readonly ENVIRONMENT="${AWS_CONFIG_POC_ENVIRONMENT:-poc}"
readonly NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"
readonly EXPECTED_RECORDER_NAME="${NAME_PREFIX}-recorder"
readonly EXPECTED_DELIVERY_CHANNEL_NAME="${NAME_PREFIX}-delivery"
readonly EXPECTED_RULE_NAME="${NAME_PREFIX}-s3-versioning"
readonly EXPECTED_PACK_NAME="${NAME_PREFIX}-s3-pack"
readonly EXPECTED_PACK_ENCRYPTION_RULE_NAME="${NAME_PREFIX}-pack-encryption"
readonly EXPECTED_PACK_PUBLIC_READ_RULE_NAME="${NAME_PREFIX}-pack-public-read"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd -- "${SCRIPT_DIR}/../terraform" && pwd)"

fail() {
  echo "PRECHECK FAILED: $*" >&2
  exit 2
}

echo "Checking AWS account and region..."
actual_account_id="$(aws --no-cli-pager sts get-caller-identity \
  --query Account --output text --region "$EXPECTED_REGION")"

[[ "$actual_account_id" == "$EXPECTED_ACCOUNT_ID" ]] || fail \
  "expected account ${EXPECTED_ACCOUNT_ID}, got ${actual_account_id}"

configured_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$configured_region" ]]; then
  configured_region="$(aws configure get region 2>/dev/null || true)"
fi

if [[ -n "$configured_region" && "$configured_region" != "$EXPECTED_REGION" ]]; then
  fail "configured AWS region is ${configured_region}; expected ${EXPECTED_REGION}"
fi

echo "Checking the existing AWS Config singleton resources..."
recorder_names="$(aws --no-cli-pager configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[].name' --output text --region "$EXPECTED_REGION")"
delivery_channel_names="$(aws --no-cli-pager configservice describe-delivery-channels \
  --query 'DeliveryChannels[].name' --output text --region "$EXPECTED_REGION")"

[[ "$recorder_names" == "None" ]] && recorder_names=""
[[ "$delivery_channel_names" == "None" ]] && delivery_channel_names=""

state_output=""
if ! state_output="$(terraform -chdir="$TF_DIR" state list 2>&1)"; then
  if [[ "$state_output" == *"No state file was found"* ]]; then
    state_output=""
  else
    fail "could not read Terraform state: ${state_output}"
  fi
fi
state_resources="$state_output"
state_has() {
  grep -Fqx -- "$1" <<<"$state_resources"
}

assert_only_expected_name() {
  local resource_kind="$1"
  local actual_names="$2"
  local expected_name="$3"
  local state_address="$4"

  for actual_name in $actual_names; do
    [[ "$actual_name" == "$expected_name" ]] || fail \
      "${resource_kind} ${actual_name} is not owned by this Terraform PoC"
  done

  state_has "$state_address" || fail \
    "${resource_kind} ${expected_name} exists but is not in this Terraform state"
}

if [[ -n "$recorder_names" || -n "$delivery_channel_names" ]]; then
  state_has "aws_config_configuration_recorder.poc" || fail \
    "an existing Configuration Recorder is not owned by this Terraform state"
  state_has "aws_config_delivery_channel.poc" || fail \
    "an existing Delivery Channel is not owned by this Terraform state"
  assert_only_expected_name \
    "Configuration Recorder" "$recorder_names" "$EXPECTED_RECORDER_NAME" \
    "aws_config_configuration_recorder.poc"
  assert_only_expected_name \
    "Delivery Channel" "$delivery_channel_names" "$EXPECTED_DELIVERY_CHANNEL_NAME" \
    "aws_config_delivery_channel.poc"
  echo "Existing singleton resources match this Terraform state."
else
  echo "No existing Configuration Recorder or Delivery Channel found."
fi

echo "Checking existing Config rules and conformance packs..."
rule_names="$(aws --no-cli-pager configservice describe-config-rules \
  --query 'ConfigRules[].ConfigRuleName' --output text --region "$EXPECTED_REGION")"
pack_names="$(aws --no-cli-pager configservice describe-conformance-packs \
  --query 'ConformancePackDetails[].ConformancePackName' --output text --region "$EXPECTED_REGION")"

[[ "$rule_names" == "None" ]] && rule_names=""
[[ "$pack_names" == "None" ]] && pack_names=""

if [[ -n "$rule_names" ]]; then
  for rule_name in $rule_names; do
    case "$rule_name" in
      "$EXPECTED_RULE_NAME")
        state_has "aws_config_config_rule.s3_versioning" || fail \
          "standalone Config Rule is not in this Terraform state"
        ;;
      "$EXPECTED_PACK_ENCRYPTION_RULE_NAME"|"$EXPECTED_PACK_PUBLIC_READ_RULE_NAME")
        state_has "aws_config_conformance_pack.s3" || fail \
          "Conformance Pack rule is not owned by this Terraform state"
        ;;
      *)
        fail "existing Config Rule ${rule_name} is not owned by this Terraform PoC"
        ;;
    esac
  done
fi

if [[ -n "$pack_names" ]]; then
  assert_only_expected_name \
    "Conformance Pack" "$pack_names" "$EXPECTED_PACK_NAME" \
    "aws_config_conformance_pack.s3"
fi

echo "Checking the pre-existing AWS Config service-linked role..."
role_arn="$(aws --no-cli-pager iam get-role \
  --role-name AWSServiceRoleForConfig \
  --query 'Role.Arn' --output text --region "$EXPECTED_REGION")" || fail \
  "AWSServiceRoleForConfig does not exist; this PoC will not create it"

[[ "$role_arn" == "arn:aws:iam::${EXPECTED_ACCOUNT_ID}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig" ]] || fail \
  "unexpected AWSServiceRoleForConfig ARN: ${role_arn}"

echo "PRECHECK PASSED: account=${EXPECTED_ACCOUNT_ID} region=${EXPECTED_REGION}"
echo "The service-linked role is data-only; no role mutation is performed."
