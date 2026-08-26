resource "aws_apigatewayv2_api" "this" {
  name          = "${var.app}-${var.env}-${var.name}"
  protocol_type = "HTTP"

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_apigatewayv2_authorizer" "api_key" {
  count = var.enable_auth ? 1 : 0

  api_id                            = aws_apigatewayv2_api.this.id
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = var.authorizer_lambda_invoke_arn
  identity_sources                  = ["$request.header.x-api-key"]
  name                              = "${var.app}-${var.env}-authorizer"
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
}

resource "aws_lambda_permission" "authorizer" {
  count = var.enable_auth ? 1 : 0

  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = var.authorizer_lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_events" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /events"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"

  # CKV_AWS_309: the route always specifies an authorization type. When the
  # custom API-key authorizer is enabled we use CUSTOM; otherwise we fall back
  # to AWS_IAM (SigV4) so the route is never left unauthenticated.
  authorization_type = var.enable_auth ? "CUSTOM" : "AWS_IAM"
  authorizer_id      = var.enable_auth ? aws_apigatewayv2_authorizer.api_key[0].id : null
}

# Access log group for the API stage
resource "aws_cloudwatch_log_group" "api_access" {
  name = "/aws/apigateway/${var.app}-${var.env}-${var.name}"
  # CKV_AWS_338: Retain logs for at least 1 year
  retention_in_days = 365

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}-access-logs"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # CKV_AWS_76: Enable access logging
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      ip                      = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}-stage"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
