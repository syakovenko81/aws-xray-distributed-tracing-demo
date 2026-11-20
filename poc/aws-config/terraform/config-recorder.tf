resource "aws_config_configuration_recorder" "poc" {
  name     = local.recorder_name
  role_arn = data.aws_iam_role.config_service_linked.arn

  recording_group {
    all_supported = false

    resource_types = [
      "AWS::S3::Bucket",
      "AWS::Config::ResourceCompliance",
    ]
  }
}

resource "aws_config_delivery_channel" "poc" {
  name           = local.delivery_channel_name
  s3_bucket_name = aws_s3_bucket.config_history.bucket

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [
    aws_config_configuration_recorder.poc,
    aws_s3_bucket_policy.config_history,
  ]
}

resource "aws_config_configuration_recorder_status" "poc" {
  name       = aws_config_configuration_recorder.poc.name
  is_enabled = true

  depends_on = [
    aws_config_delivery_channel.poc,
  ]
}
