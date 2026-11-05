data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  api_name    = "${local.name_prefix}-api"
  table_name  = "${local.name_prefix}-records"
  lambda_a    = "${local.name_prefix}-lambda-a"
  lambda_b    = "${local.name_prefix}-lambda-b"
}

data "archive_file" "lambda_a" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/lambda_a"
  output_path = "${path.module}/.terraform/${local.lambda_a}.zip"
}

data "archive_file" "lambda_b" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/lambda_b"
  output_path = "${path.module}/.terraform/${local.lambda_b}.zip"
}

resource "aws_dynamodb_table" "records" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "record_id"

  attribute {
    name = "record_id"
    type = "S"
  }
}

resource "aws_cloudwatch_log_group" "lambda_a" {
  name              = "/aws/lambda/${local.lambda_a}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "lambda_b" {
  name              = "/aws/lambda/${local.lambda_b}"
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

resource "aws_iam_role" "lambda_a" {
  name               = "${local.lambda_a}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role" "lambda_b" {
  name               = "${local.lambda_b}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_a_permissions" {
  statement {
    sid    = "WriteLambdaLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda_a.arn}:*"]
  }

  statement {
    sid       = "InvokeLambdaB"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.lambda_b.arn, "${aws_lambda_function.lambda_b.arn}:*"]
  }

  statement {
    sid    = "WriteXRaySegments"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "lambda_b_permissions" {
  statement {
    sid    = "WriteLambdaLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda_b.arn}:*"]
  }

  statement {
    sid       = "WriteDemoRecord"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.records.arn]
  }

  statement {
    sid    = "WriteXRaySegments"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_a" {
  name   = "${local.lambda_a}-permissions"
  role   = aws_iam_role.lambda_a.id
  policy = data.aws_iam_policy_document.lambda_a_permissions.json
}

resource "aws_iam_role_policy" "lambda_b" {
  name   = "${local.lambda_b}-permissions"
  role   = aws_iam_role.lambda_b.id
  policy = data.aws_iam_policy_document.lambda_b_permissions.json
}

resource "aws_lambda_function" "lambda_b" {
  function_name    = local.lambda_b
  role             = aws_iam_role.lambda_b.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda_b.output_path
  source_code_hash = data.archive_file.lambda_b.output_base64sha256
  architectures    = ["x86_64"]
  memory_size      = 128
  timeout          = 10

  tracing_config {
    mode = "Active"
  }

  layers = [var.adot_python_layer_arn]

  environment {
    variables = {
      AWS_LAMBDA_EXEC_WRAPPER              = "/opt/otel-instrument"
      OTEL_PROPAGATORS                     = "tracecontext,baggage,xray-lambda"
      OTEL_AWS_APPLICATION_SIGNALS_ENABLED = "false"
      OTEL_METRICS_EXPORTER                = "none"
      OTEL_LOGS_EXPORTER                   = "none"
      OTEL_SERVICE_NAME                    = local.lambda_b
      TABLE_NAME                           = aws_dynamodb_table.records.name
    }
  }

  depends_on = [aws_iam_role_policy.lambda_b]
}

resource "aws_lambda_function" "lambda_a" {
  function_name    = local.lambda_a
  role             = aws_iam_role.lambda_a.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda_a.output_path
  source_code_hash = data.archive_file.lambda_a.output_base64sha256
  architectures    = ["x86_64"]
  memory_size      = 128
  timeout          = 15

  tracing_config {
    mode = "Active"
  }

  layers = [var.adot_python_layer_arn]

  environment {
    variables = {
      AWS_LAMBDA_EXEC_WRAPPER              = "/opt/otel-instrument"
      OTEL_PROPAGATORS                     = "tracecontext,baggage,xray-lambda"
      OTEL_AWS_APPLICATION_SIGNALS_ENABLED = "false"
      OTEL_METRICS_EXPORTER                = "none"
      OTEL_LOGS_EXPORTER                   = "none"
      OTEL_SERVICE_NAME                    = local.lambda_a
      LAMBDA_B_NAME                        = aws_lambda_function.lambda_b.function_name
    }
  }

  depends_on = [aws_iam_role_policy.lambda_a]
}

resource "aws_api_gateway_rest_api" "demo" {
  name = local.api_name

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.demo.id
  parent_id   = aws_api_gateway_rest_api.demo.root_resource_id
  path_part   = "events"
}

resource "aws_api_gateway_method" "events_post" {
  rest_api_id   = aws_api_gateway_rest_api.demo.id
  resource_id   = aws_api_gateway_resource.events.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "events_post" {
  rest_api_id             = aws_api_gateway_rest_api.demo.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.events_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.lambda_a.invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_a.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.demo.execution_arn}/*/POST/events"
}

resource "aws_api_gateway_deployment" "demo" {
  rest_api_id = aws_api_gateway_rest_api.demo.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.events.id,
      aws_api_gateway_method.events_post.id,
      aws_api_gateway_integration.events_post.id,
    ]))
  }

  depends_on = [aws_api_gateway_integration.events_post]
}

resource "aws_api_gateway_stage" "demo" {
  rest_api_id          = aws_api_gateway_rest_api.demo.id
  deployment_id        = aws_api_gateway_deployment.demo.id
  stage_name           = var.environment
  xray_tracing_enabled = true
  description          = "Low-cost X-Ray tracing demo stage"
}
