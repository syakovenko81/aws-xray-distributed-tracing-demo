# AWS Config audit and configuration tracking PoC

This is an isolated Proof of Concept for AWS Config in account
`661200526584`, region `us-east-1`. It does not use resources from the main
X-Ray demo or `poc/aws-code-suite/`.

AWS Config has account-level singleton resources in a region: only one
customer-managed Configuration Recorder and one Delivery Channel can exist for
an account and region. The preflight script therefore fails closed when it
finds resources that are not already owned by this Terraform state. It never
imports, updates, or deletes an existing AWS Config resource.

## Architecture

```text
Test S3 bucket (versioning initially absent)
        |
        v
Configuration Recorder
  AWS::S3::Bucket
  AWS::Config::ResourceCompliance
        |
        v
Delivery Channel -> dedicated Config history S3 bucket
        |
        +--> managed rule: S3_BUCKET_VERSIONING_ENABLED
        |
        +--> Conformance Pack:
              S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED
              S3_BUCKET_PUBLIC_READ_PROHIBITED
```

Terraform uses the pre-existing `AWSServiceRoleForConfig` through an IAM data
source. The service-linked role is not an AWS resource managed by this stack.

The history bucket uses SSE-S3, Block Public Access, bucket-owner-enforced
ownership, TLS-only access, and `force_destroy = false`. The test bucket also
uses SSE-S3, Block Public Access, ownership controls, and a TLS-only policy.
There is intentionally no Terraform `aws_s3_bucket_versioning` resource for
the test bucket: versioning is enabled manually during the exercise.

## Files

- `terraform/s3.tf` — history bucket, test bucket, encryption, public access,
  ownership controls, and bucket policies.
- `terraform/data.tf` — account, partition, and existing Config service-linked
  role data sources.
- `terraform/config-recorder.tf` — recorder, Delivery Channel, and recorder
  status.
- `terraform/config-rules.tf` — scoped managed versioning rule.
- `terraform/conformance-pack.tf` — custom pack with two S3 managed rules.
- `terraform/templates/conformance-pack.yaml.tftpl` — pack template.
- `scripts/preflight.sh` — account, region, ownership, and singleton checks.
- `.gitignore` — local Terraform state, plans, credentials, and artifacts.

Terraform state is local to `poc/aws-config/terraform/terraform.tfstate` and is
ignored by Git. No backend is configured.

## Preflight and deployment order

Run the preflight with the same AWS credentials that Terraform will use:

```bash
cd poc/aws-config
bash scripts/preflight.sh
```

If `project_name` or `environment` are overridden for Terraform, provide the
same values to preflight:

```bash
AWS_CONFIG_POC_PROJECT_NAME="my-config-poc" \
AWS_CONFIG_POC_ENVIRONMENT="dev" \
bash scripts/preflight.sh
```

The preflight verifies:

1. account `661200526584`;
2. region `us-east-1`;
3. absence of foreign Configuration Recorders and Delivery Channels;
4. absence of foreign Config Rules and Conformance Packs;
5. existence of `AWSServiceRoleForConfig`;
6. Terraform state ownership if singleton resources already exist.

The intended Terraform dependency order is:

1. S3 buckets, security settings, and bucket policies;
2. Configuration Recorder;
3. Delivery Channel after the Recorder and history bucket policy;
4. Configuration Recorder Status after the Delivery Channel;
5. Config Rule and Conformance Pack after the recorder is running.

Review the plan before any future apply:

```bash
cd poc/aws-config/terraform
terraform init
terraform plan -out=aws-config.tfplan
```

Do not run `terraform apply` until the plan and the singleton ownership check
have been reviewed.

## Verification commands

Check the recorder and Delivery Channel:

```bash
REGION="us-east-1"

aws configservice describe-configuration-recorders --region "$REGION"
aws configservice describe-configuration-recorder-status --region "$REGION"
aws configservice describe-delivery-channels --region "$REGION"
aws configservice describe-delivery-channel-status --region "$REGION"
```

Get PoC names after deployment:

```bash
cd poc/aws-config/terraform
BUCKET="$(terraform output -raw test_bucket_name)"
HISTORY_BUCKET="$(terraform output -raw config_history_bucket_name)"
RULE="$(terraform output -raw versioning_rule_name)"
PACK="$(terraform output -raw conformance_pack_name)"
```

Inspect Config delivery objects and request a snapshot when evidence collection
is intended:

```bash
aws s3api list-objects-v2 \
  --bucket "$HISTORY_BUCKET" \
  --prefix "AWSLogs/661200526584/Config/" \
  --region "$REGION"

aws configservice deliver-config-snapshot \
  --delivery-channel-name "$(terraform output -raw delivery_channel_name)" \
  --region "$REGION"
```

The snapshot command is an active AWS Config API operation and is not part of
the read-only preflight.

## NON_COMPLIANT to COMPLIANT exercise

The test bucket is created without a versioning resource. After the first
evaluation, check the initial state:

```bash
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name "$RULE" \
  --region "$REGION"
```

Expected result: `NON_COMPLIANT` for the test bucket. AWS Config evaluation is
asynchronous. If needed during the hands-on exercise, request a new evaluation:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names "$RULE" \
  --region "$REGION"
```

Enable versioning manually:

```bash
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled \
  --region "$REGION"
```

After the next evaluation, repeat the compliance query and capture
`COMPLIANT`.

## Configuration History and Resource Timeline

CLI history query:

```bash
aws configservice get-resource-config-history \
  --resource-type AWS::S3::Bucket \
  --resource-id "$BUCKET" \
  --region "$REGION"
```

In the AWS Console, open **Config → Resources**, select the test bucket, and
open **Resource Timeline**. Capture the bucket creation, versioning change, and
compliance events.

The recorder includes `AWS::Config::ResourceCompliance` so compliance history
can be represented in the timeline. The S3 bucket configuration history is
independent of the rule result history.

## Conformance Pack

The custom pack contains two uniquely named Config Rules, both scoped to the
test bucket:

- `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED`;
- `S3_BUCKET_PUBLIC_READ_PROHIBITED`.

They intentionally do not duplicate the standalone versioning rule. This keeps
the compliance evidence clear and avoids duplicate evaluations for the same
control.

Inspect the pack:

```bash
aws configservice describe-conformance-pack-status \
  --conformance-pack-name "$PACK" \
  --region "$REGION"

aws configservice get-conformance-pack-compliance-details \
  --conformance-pack-name "$PACK" \
  --region "$REGION"
```

## Evidence checklist

- account and region identity;
- preflight result;
- Terraform plan;
- recorder configuration and recording status;
- Delivery Channel and delivery status;
- history bucket security settings;
- S3 history/snapshot object listing;
- standalone rule with `NON_COMPLIANT` status;
- manual versioning change;
- standalone rule with `COMPLIANT` status;
- Resource Timeline and Configuration History;
- Conformance Pack status and two rule results;
- final list of PoC resources.

## Safe deletion

Before deletion, confirm that no external AWS Config workload uses the
recorder, Delivery Channel, or history bucket:

```bash
bash poc/aws-config/scripts/preflight.sh
cd poc/aws-config/terraform
terraform plan -destroy
```

If the recorder or Delivery Channel is shared, do not destroy them. Remove only
PoC rules, the Conformance Pack, and test bucket after reviewing the plan.

The history bucket has `force_destroy = false`; Terraform will not silently
delete Config history objects. Export evidence first, then remove objects and
the bucket only as an explicitly reviewed cleanup step. The
`AWSServiceRoleForConfig` role remains because it is a data source and is never
managed by this stack.
