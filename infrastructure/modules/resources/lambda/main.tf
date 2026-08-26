data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.terraform/lambda-builds/${var.name}.zip"
}

resource "aws_lambda_function" "this" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.app}-${var.env}-${var.name}"
  role             = aws_iam_role.lambda_role.arn
  handler          = var.handler
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = var.runtime
  timeout          = var.timeout
  memory_size      = var.memory_size

  environment {
    variables = var.environment_variables
  }

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "${var.app}-${var.env}-${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}-role"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_policy" {
  count = length(var.policy_statements) > 0 ? 1 : 0
  name  = "${var.app}-${var.env}-${var.name}-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for stmt in var.policy_statements : {
        Effect   = stmt.effect
        Action   = stmt.actions
        Resource = stmt.resources
      }
    ]
  })

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}-policy"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_iam_role_policy_attachment" "lambda_custom" {
  count      = length(var.policy_statements) > 0 ? 1 : 0
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy[0].arn
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name = "/aws/lambda/${aws_lambda_function.this.function_name}"
  # CKV_AWS_338: Retain logs for at least 1 year
  retention_in_days = 365

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}-logs"
    Environment = var.env
    Application = var.app
  }
}
