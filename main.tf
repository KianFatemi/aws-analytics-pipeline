provider "aws" {
  region = "us-east-1"
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "analytics-pipeline-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "index.js" # Make sure this file exists!
  output_path = "lambda_function.zip"
}

resource "aws_lambda_function" "analytics_ingestor" {
  function_name    = "analytics-ingestor"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
   environment {
    variables = {
      S3_BUCKET_NAME = aws_s3_bucket.raw_events_bucket.bucket
      DDB_TABLE_NAME = aws_dynamodb_table.events_table.name
    }
  }
}

resource "aws_api_gateway_rest_api" "rest_api" {
  name = "AnalyticsAPI-REST"
}

resource "aws_api_gateway_resource" "event_resource" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "event"
}

resource "aws_api_gateway_method" "post_method" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.event_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.event_resource.id
  http_method = aws_api_gateway_method.post_method.http_method
  
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.analytics_ingestor.invoke_arn
}

resource "aws_lambda_permission" "api_gw_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analytics_ingestor.function_name
  principal     = "apigateway.amazonaws.com"
  
  source_arn = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/${aws_api_gateway_method.post_method.http_method}${aws_api_gateway_resource.event_resource.path}"
}

resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.event_resource.id,
      aws_api_gateway_method.post_method.id,
      aws_api_gateway_integration.lambda_integration.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = "test"
}

output "api_endpoint_url" {
  value = "${aws_api_gateway_stage.api_stage.invoke_url}/${aws_api_gateway_resource.event_resource.path_part}"
}

resource "aws_s3_bucket" "raw_events_bucket" {
  bucket = "analytics-raw-events-bucket-${random_id.id.hex}" # Unique bucket name
}

resource "random_id" "id" {
  byte_length = 8
}

resource "aws_dynamodb_table" "events_table" {
  name           = "processed-events"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "eventId"

  attribute {
    name = "eventId"
    type = "S" # S means String
  }
}

resource "aws_iam_role_policy" "lambda_data_permissions" {
  name = "lambda-data-access-policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "s3:PutObject",
        Effect   = "Allow",
        Resource = "${aws_s3_bucket.raw_events_bucket.arn}/*"
      },
      {
        Action   = "dynamodb:PutItem",
        Effect   = "Allow",
        Resource = aws_dynamodb_table.events_table.arn
      }
    ]
  })
}