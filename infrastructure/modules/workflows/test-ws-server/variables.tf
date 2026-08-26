variable "app" {
  description = "Application name"
  type        = string
}

variable "env" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "cluster_id" {
  description = "ECS cluster ID to deploy into"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the task"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for the task"
  type        = string
}

variable "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for service discovery namespace"
  type        = string
}
