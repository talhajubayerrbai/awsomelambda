terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

#  Variables 

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name (used for resource naming and tagging)"
  type        = string
}

variable "tf_state_bucket" {
  description = "S3 bucket that holds Terraform state AND Lambda zip artifacts"
  type        = string
}

variable "image_uri" {
  description = "Unused for Lambda/S3 deploys; accepted so destroy vars stay consistent"
  type        = string
  default     = "placeholder"
}

#  IAM role for Lambda 

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project_name}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

#  Lambda function 

resource "aws_lambda_function" "app" {
  function_name = "${var.project_name}-app"
  role          = aws_iam_role.lambda_exec.arn

  runtime     = "python3.11"
  handler     = "index.lambda_handler"
  memory_size = 128
  timeout     = 30

  s3_bucket = var.tf_state_bucket
  s3_key    = "${var.project_name}/lambda.zip"

  environment {
    variables = {
      APP_ENV = "production"
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

#  API Gateway HTTP API 

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project_name}-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.app.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  depends_on = [aws_apigatewayv2_route.default]
}

#  Lambda permission for API Gateway 

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

#  Outputs 

output "app_url" {
  description = "Public API Gateway invoke URL"
  value       = aws_apigatewayv2_stage.default.invoke_url
}