output "codecommit_repository_name" {
  value = aws_codecommit_repository.poc.repository_name
}

output "codecommit_clone_url_http" {
  value = aws_codecommit_repository.poc.clone_url_http
}

output "codepipeline_name" {
  value = aws_codepipeline.poc.name
}

output "lambda_function_name" {
  value = aws_lambda_function.poc.function_name
}

output "lambda_alias_name" {
  value = aws_lambda_alias.live.name
}

output "artifact_bucket_name" {
  value = aws_s3_bucket.artifacts.bucket
}
