resource "aws_config_config_rule" "s3_versioning" {
  name        = local.versioning_rule_name
  description = "Checks versioning only on the isolated AWS Config PoC test bucket."

  scope {
    compliance_resource_id = aws_s3_bucket.test.id
    compliance_resource_types = [
      "AWS::S3::Bucket",
    ]
  }

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_VERSIONING_ENABLED"
  }

  depends_on = [
    aws_config_configuration_recorder_status.poc,
  ]
}
