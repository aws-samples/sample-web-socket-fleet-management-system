variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "ssm_config_path" {
  description = "SSM Parameter Store path for project configuration"
  type        = string
  default     = "/ws-fleet/dev/config"
}
