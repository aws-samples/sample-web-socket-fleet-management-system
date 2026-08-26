variable "name" {
  description = "Name of the DynamoDB table"
  type        = string
}

variable "partition_key" {
  description = "Partition key attribute name"
  type        = string
}

variable "sort_key" {
  description = "Sort key attribute name (optional)"
  type        = string
  default     = null
}

variable "app" {
  description = "Application name"
  type        = string
}

variable "env" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "ttl_enabled" {
  description = "Enable TTL"
  type        = bool
  default     = false
}

variable "ttl_attribute" {
  description = "TTL attribute name"
  type        = string
  default     = "ttl"
}

variable "gsi_config" {
  description = "Global Secondary Index configuration"
  type = object({
    name            = string
    hash_key        = string
    range_key       = string
    projection_type = string
  })
  default = null
}
