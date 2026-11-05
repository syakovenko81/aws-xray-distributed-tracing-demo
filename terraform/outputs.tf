output "api_endpoint" {
  description = "POST endpoint for the demo API."
  value       = "https://${aws_api_gateway_rest_api.demo.id}.execute-api.${var.region}.amazonaws.com/${aws_api_gateway_stage.demo.stage_name}/events"
}

output "lambda_a_name" {
  value = aws_lambda_function.lambda_a.function_name
}

output "lambda_b_name" {
  value = aws_lambda_function.lambda_b.function_name
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.records.name
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "deployment_region" {
  value = var.region
}
