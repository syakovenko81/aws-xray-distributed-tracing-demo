output "aws_account_id" {
  description = "AWS account used by this PoC."
  value       = data.aws_caller_identity.current.account_id
}

output "deployment_region" {
  description = "AWS region used by this PoC."
  value       = var.region
}

output "config_history_bucket_name" {
  description = "S3 bucket receiving AWS Config history and snapshots."
  value       = aws_s3_bucket.config_history.bucket
}

output "test_bucket_name" {
  description = "S3 bucket used for the NON_COMPLIANT to COMPLIANT exercise."
  value       = aws_s3_bucket.test.bucket
}

output "configuration_recorder_name" {
  value = aws_config_configuration_recorder.poc.name
}

output "delivery_channel_name" {
  value = aws_config_delivery_channel.poc.name
}

output "versioning_rule_name" {
  value = aws_config_config_rule.s3_versioning.name
}

output "conformance_pack_name" {
  value = aws_config_conformance_pack.s3.name
}

output "config_service_linked_role_arn" {
  description = "Existing AWS Config service-linked role used as a data source."
  value       = data.aws_iam_role.config_service_linked.arn
}
