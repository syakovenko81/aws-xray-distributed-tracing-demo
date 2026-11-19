resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${local.codebuild_project_name}"
  retention_in_days = 7
}

resource "aws_iam_role" "codebuild" {
  name               = "${local.codebuild_project_name}-service-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
}

data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "codebuild_permissions" {
  statement {
    sid    = "WriteBuildLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.codebuild.arn}:*"]
  }

  statement {
    sid    = "UsePipelineArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid    = "ListPipelineArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid    = "PublishOnlyPoCLambdaVersion"
    effect = "Allow"
    actions = [
      "lambda:GetAlias",
      "lambda:GetFunction",
      "lambda:UpdateFunctionCode",
    ]
    resources = [aws_lambda_function.poc.arn]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${local.codebuild_project_name}-permissions"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_permissions.json
}

resource "aws_codebuild_project" "poc" {
  name         = local.codebuild_project_name
  description  = "Build, test and publish an isolated Lambda version for CodeDeploy"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "LAMBDA_FUNCTION_NAME"
      value = aws_lambda_function.poc.function_name
    }

    environment_variable {
      name  = "LAMBDA_ALIAS_NAME"
      value = aws_lambda_alias.live.name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "build/buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "build"
    }
  }

  depends_on = [aws_iam_role_policy.codebuild]
}
