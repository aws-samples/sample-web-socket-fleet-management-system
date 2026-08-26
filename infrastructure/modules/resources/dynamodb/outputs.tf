output "table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.this.name
}

output "table_arn" {
  description = "ARN of the DynamoDB table"
  value       = aws_dynamodb_table.this.arn
}

output "table_id" {
  description = "ID of the DynamoDB table"
  value       = aws_dynamodb_table.this.id
}

output "gsi_arn" {
  description = "ARN of the GSI (if configured)"
  value       = var.gsi_config != null ? "${aws_dynamodb_table.this.arn}/index/${var.gsi_config.name}" : null
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the table"
  value       = aws_kms_key.this.arn
}
