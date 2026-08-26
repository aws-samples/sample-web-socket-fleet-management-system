variable "name" {
  description = "Name of the API Gateway"
  type        = string
}

variable "app" {
  description = "Application name"
  type        = string
}

variable "env" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "lambda_invoke_arn" {
  description = "Lambda function invoke ARN"
  type        = string
}

variable "lambda_function_name" {
  description = "Lambda function name"
  type        = string
}

variable "authorizer_lambda_invoke_arn" {
  description = "Authorizer Lambda invoke ARN"
  type        = string
  default     = ""
}

variable "authorizer_lambda_function_name" {
  description = "Authorizer Lambda function name"
  type        = string
  default     = ""
}

variable "enable_auth" {
  description = "Enable API key authentication (secure-by-default)"
  type        = bool
  default     = true
}
