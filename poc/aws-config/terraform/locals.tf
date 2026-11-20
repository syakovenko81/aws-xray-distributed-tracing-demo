locals {
  name_prefix = "${var.project_name}-${var.environment}"

  history_bucket_prefix = "${local.name_prefix}-history-"
  test_bucket_prefix    = "${local.name_prefix}-test-"

  recorder_name         = "${local.name_prefix}-recorder"
  delivery_channel_name = "${local.name_prefix}-delivery"
  versioning_rule_name  = "${local.name_prefix}-s3-versioning"
  conformance_pack_name = "${local.name_prefix}-s3-pack"

  pack_encryption_rule_name  = "${local.name_prefix}-pack-encryption"
  pack_public_read_rule_name = "${local.name_prefix}-pack-public-read"
}
