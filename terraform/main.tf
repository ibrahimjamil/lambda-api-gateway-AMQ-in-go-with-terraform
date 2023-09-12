terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
    }
    random = {
      source  = "hashicorp/random"
    }
    archive = {
      source  = "hashicorp/archive"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}


## S3 Lambda bucket creation and access restriction
resource "random_pet" "lambda_bucket_name" {
  prefix = "lambda"
  length = 2
}

resource "aws_s3_bucket" "lambda_bucket" {
  bucket        = random_pet.lambda_bucket_name.id
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "lambda_bucket" {
  bucket = aws_s3_bucket.lambda_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# create rabbit mq broker
resource "aws_mq_broker" "active_mq_broker" {
  broker_name = "active_mq_broker_ibrahim"
  engine_type        = "ActiveMQ"
  engine_version     = "5.15.9"
  host_instance_type = "mq.t2.micro"
  publicly_accessible = "true"
  # add security group here

  user {
    username = "root"
    password = "Admin@123456"
    console_access = "true"
  }
}

data "aws_mq_broker" "active_mq_broker" {
  broker_name = aws_mq_broker.active_mq_broker.broker_name
}

output "broker_endpoint" {
  value = data.aws_mq_broker.active_mq_broker
}

## Sample code for simple hello code of go
## "Resource": "arn:aws:mq:us-east-1:912165650675:broker/active_mq_broker_ibrahim"
#{
#"Effect": "Allow",
#"Action": "*",
#"Resource": "arn:aws:mq:us-east-1:912165650675:broker/active_mq_broker_ibrahim"
#}

# create role with policy attach to it
resource "aws_iam_role" "hello_lambda_exec" {
  name = "hello-lambda"

  managed_policy_arns = [aws_iam_policy.iam_role_mq_lambda_policy.arn]

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_policy" "iam_role_mq_lambda_policy" {
  name = "iam_role_mq_lambda_access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["*"],
        Effect   = "Allow",
        Resource = aws_mq_broker.active_mq_broker.arn
      },
    ]
  })
}

resource "aws_lambda_function" "hello" {
  function_name = "hello"

  s3_bucket = aws_s3_bucket.lambda_bucket.id
  s3_key    = aws_s3_object.lambda_hello.key

  runtime =  "provided.al2" # nodejs16.x | go1.x
  handler = "bootstrap"  # function.handler | main


  source_code_hash = data.archive_file.lambda_hello.output_base64sha256

  # giving lambda function role to use aws lambda and AMQ invokation in function.
  role = aws_iam_role.hello_lambda_exec.arn

  timeout = 40

  environment {
    variables = {
      MQ_ENDPOINT_IP = data.aws_mq_broker.active_mq_broker.instances[0].endpoints[2]
#      BROKER_USERNAME = "root"
#      BROKER_PASSWORD = "Admin@123456"   # after destroy
    }
  }
}


resource "aws_cloudwatch_log_group" "hello" {
  name = "/aws/lambda/${aws_lambda_function.hello.function_name}"

  retention_in_days = 14
}

data "archive_file" "lambda_hello" {
  type = "zip"

  source_dir  = "../${path.module}/helloGo"  # hello | helloGo
  output_path = "../${path.module}/hello.zip"
}

resource "aws_s3_object" "lambda_hello" {
  bucket = aws_s3_bucket.lambda_bucket.id

  key    = "hello.zip"
  source = "../hello.zip"

  source_hash =   data.archive_file.lambda_hello.output_base64sha256

}

# Api gateway setup
resource "aws_apigatewayv2_api" "main" {
  name          = "main"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "dev" {
  api_id = aws_apigatewayv2_api.main.id

  name        = "dev"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.main_api_gw.arn

    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      protocol                = "$context.protocol"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    }
    )
  }
}

resource "aws_cloudwatch_log_group" "main_api_gw" {
  name = "/aws/api-gw/${aws_apigatewayv2_api.main.name}"

  retention_in_days = 14
}


# API Gateway Integration & permission grant to lambda function to be accessed from api gateway
resource "aws_apigatewayv2_integration" "lambda_hello" {
  api_id = aws_apigatewayv2_api.main.id

  integration_uri    = aws_lambda_function.hello.invoke_arn
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "get_hello" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "GET /hello"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_hello.id}"
}

resource "aws_apigatewayv2_route" "post_hello" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "POST /hello"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_hello.id}"
}

# giving api gateway access to use lambda function.
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}


output "hello_base_url" {
  value = aws_apigatewayv2_stage.dev.invoke_url
}