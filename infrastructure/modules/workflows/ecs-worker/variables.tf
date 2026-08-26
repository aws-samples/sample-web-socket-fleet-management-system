variable "app" {
  description = "Application name"
  type        = string
}

variable "env" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
}

variable "worker_cpu" {
  description = "CPU units for worker task"
  type        = number
}

variable "worker_memory" {
  description = "Memory (MB) for worker task"
  type        = number
}

variable "desired_count" {
  description = "Desired number of ECS tasks"
  type        = number
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks"
  type        = number
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks"
  type        = number
}

variable "table_name" {
  description = "DynamoDB table name"
  type        = string
}

variable "messages_table_name" {
  description = "DynamoDB messages table name"
  type        = string
}

variable "table_arn" {
  description = "DynamoDB table ARN"
  type        = string
}

variable "messages_table_arn" {
  description = "DynamoDB messages table ARN"
  type        = string
}

variable "gsi_arn" {
  description = "DynamoDB GSI ARN"
  type        = string
}

variable "table_kms_key_arn" {
  description = "KMS key ARN for the connections table"
  type        = string
}

variable "messages_table_kms_key_arn" {
  description = "KMS key ARN for the messages table"
  type        = string
}

variable "queue_url" {
  description = "SQS queue URL"
  type        = string
}

variable "queue_arn" {
  description = "SQS queue ARN"
  type        = string
}

variable "gsi_name" {
  description = "DynamoDB GSI name"
  type        = string
}

variable "service_name_dimension" {
  description = "CloudWatch metric dimension for service name"
  type        = string
}
