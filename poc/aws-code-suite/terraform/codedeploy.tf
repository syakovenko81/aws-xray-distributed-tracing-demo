resource "aws_codedeploy_app" "poc" {
  name             = local.codedeploy_app_name
  compute_platform = "Lambda"
}

resource "aws_iam_role" "codedeploy" {
  name               = "${local.deployment_group_name}-service-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role.json
}

data "aws_iam_policy_document" "codedeploy_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "codedeploy_permissions" {
  statement {
    sid    = "ReadDeploymentRevision"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "ManagePoCLambdaDeployment"
    effect = "Allow"
    actions = [
      "lambda:GetAlias",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:InvokeFunction",
      "lambda:ListVersionsByFunction",
      "lambda:UpdateAlias",
    ]
    resources = [
      aws_lambda_function.poc.arn,
      "${aws_lambda_function.poc.arn}:*",
    ]
  }

  statement {
    sid       = "ReadDeploymentAlarm"
    effect    = "Allow"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = [aws_cloudwatch_metric_alarm.lambda_errors.arn]
  }
}

resource "aws_iam_role_policy" "codedeploy" {
  name   = "${local.deployment_group_name}-permissions"
  role   = aws_iam_role.codedeploy.id
  policy = data.aws_iam_policy_document.codedeploy_permissions.json
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.lambda_function_name}-alias-errors"
  alarm_description   = "Stops a CodeDeploy canary when the PoC Lambda alias reports errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.poc.function_name
    Resource     = "${aws_lambda_function.poc.function_name}:${aws_lambda_alias.live.name}"
  }
}

resource "aws_codedeploy_deployment_group" "poc" {
  app_name               = aws_codedeploy_app.poc.name
  deployment_group_name  = local.deployment_group_name
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.LambdaCanary10Percent5Minutes"

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    alarms  = [aws_cloudwatch_metric_alarm.lambda_errors.alarm_name]
    enabled = true
  }

  depends_on = [aws_iam_role_policy.codedeploy]
}
