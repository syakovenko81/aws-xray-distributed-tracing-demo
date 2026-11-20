resource "aws_config_conformance_pack" "s3" {
  name = local.conformance_pack_name

  template_body = templatefile(
    "${path.module}/templates/conformance-pack.yaml.tftpl",
    {
      test_bucket_name      = aws_s3_bucket.test.bucket
      encryption_rule_name  = local.pack_encryption_rule_name
      public_read_rule_name = local.pack_public_read_rule_name
    }
  )

  depends_on = [
    aws_config_configuration_recorder_status.poc,
  ]
}
