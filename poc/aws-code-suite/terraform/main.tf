data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix            = "${var.project_name}-${var.environment}"
  lambda_function_name   = "${local.name_prefix}-lambda"
  codebuild_project_name = "${local.name_prefix}-build"
  codepipeline_name      = "${local.name_prefix}-pipeline"
  codedeploy_app_name    = "${local.name_prefix}-app"
  deployment_group_name  = "${local.name_prefix}-deployment-group"
}

data "archive_file" "lambda_bootstrap" {
  type        = "zip"
  source_dir  = "${path.module}/../application"
  output_path = "${path.module}/.terraform/${local.lambda_function_name}-bootstrap.zip"

  excludes = [
    "**/__pycache__/**",
    "**/*.pyc",
  ]
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.lambda_function_name}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid    = "WriteOwnLambdaLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.lambda_function_name}-logs"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_lambda_function" "poc" {
  function_name    = local.lambda_function_name
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda_bootstrap.output_path
  source_code_hash = data.archive_file.lambda_bootstrap.output_base64sha256
  architectures    = ["x86_64"]
  memory_size      = 128
  timeout          = 10
  publish          = true

  lifecycle {
    # CodeBuild owns source updates after bootstrap; Terraform must not replace
    # a version deployed by the CI/CD pipeline on a later infrastructure apply.
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_iam_role_policy.lambda]
}

resource "aws_lambda_alias" "live" {
  name             = var.lambda_alias_name
  description      = "Stable alias shifted by CodeDeploy canary deployments"
  function_name    = aws_lambda_function.poc.function_name
  function_version = aws_lambda_function.poc.version

  lifecycle {
    # CodeDeploy, not Terraform, owns alias transitions after creation.
    ignore_changes = [function_version]
  }
}
