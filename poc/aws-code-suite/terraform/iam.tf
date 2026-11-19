data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${local.codepipeline_name}-service-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
}

data "aws_iam_policy_document" "codepipeline_permissions" {
  statement {
    sid    = "UseSourceRepository"
    effect = "Allow"
    actions = [
      "codecommit:CancelUploadArchive",
      "codecommit:GetBranch",
      "codecommit:GetCommit",
      "codecommit:GetRepository",
      "codecommit:GetUploadArchiveStatus",
      "codecommit:UploadArchive",
    ]
    resources = [aws_codecommit_repository.poc.arn]
  }

  statement {
    sid    = "UseArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid    = "ReadWritePipelineArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "RunCodeBuild"
    effect    = "Allow"
    actions   = ["codebuild:StartBuild"]
    resources = [aws_codebuild_project.poc.arn]
  }

  statement {
    sid       = "PollCodeBuildProject"
    effect    = "Allow"
    actions   = ["codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.poc.arn]
  }

  statement {
    sid    = "ManageCodeDeployApplication"
    effect = "Allow"
    actions = [
      "codedeploy:GetApplication",
      "codedeploy:GetApplicationRevision",
      "codedeploy:ListDeploymentGroups",
      "codedeploy:RegisterApplicationRevision",
    ]
    resources = [aws_codedeploy_app.poc.arn]
  }

  statement {
    sid    = "StartAndPollCodeDeployDeployment"
    effect = "Allow"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentGroup",
      "codedeploy:ListDeployments",
    ]
    resources = [aws_codedeploy_deployment_group.poc.arn]
  }

  statement {
    sid       = "ReadDeploymentConfig"
    effect    = "Allow"
    actions   = ["codedeploy:GetDeploymentConfig"]
    resources = ["arn:${data.aws_partition.current.partition}:codedeploy:${var.region}:${data.aws_caller_identity.current.account_id}:deploymentconfig:*"]
  }

  statement {
    sid       = "ListDeploymentConfigurations"
    effect    = "Allow"
    actions   = ["codedeploy:ListDeploymentConfigs"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "${local.codepipeline_name}-permissions"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline_permissions.json
}

data "aws_iam_policy_document" "eventbridge_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eventbridge" {
  name               = "${local.codepipeline_name}-events-role"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume_role.json
}

data "aws_iam_policy_document" "eventbridge_permissions" {
  statement {
    sid       = "StartOnlyThisPipeline"
    effect    = "Allow"
    actions   = ["codepipeline:StartPipelineExecution"]
    resources = [aws_codepipeline.poc.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge" {
  name   = "${local.codepipeline_name}-events-permissions"
  role   = aws_iam_role.eventbridge.id
  policy = data.aws_iam_policy_document.eventbridge_permissions.json
}
