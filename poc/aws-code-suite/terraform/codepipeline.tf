resource "aws_codepipeline" "poc" {
  name     = local.codepipeline_name
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "CodeCommit"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName       = aws_codecommit_repository.poc.repository_name
        BranchName           = "main"
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "CodeBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.poc.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "CodeDeployLambda"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ApplicationName     = aws_codedeploy_app.poc.name
        DeploymentGroupName = aws_codedeploy_deployment_group.poc.deployment_group_name
      }
    }
  }

  depends_on = [aws_iam_role_policy.codepipeline]
}

resource "aws_cloudwatch_event_rule" "codecommit_main_updated" {
  name        = "${local.codepipeline_name}-source-updated"
  description = "Start the isolated Code Suite pipeline when main changes"

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    detail-type = ["CodeCommit Repository State Change"]
    resources   = [aws_codecommit_repository.poc.arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceName = ["main"]
    }
  })
}

resource "aws_cloudwatch_event_target" "codepipeline" {
  rule      = aws_cloudwatch_event_rule.codecommit_main_updated.name
  target_id = "StartCodePipeline"
  arn       = aws_codepipeline.poc.arn
  role_arn  = aws_iam_role.eventbridge.arn
}
