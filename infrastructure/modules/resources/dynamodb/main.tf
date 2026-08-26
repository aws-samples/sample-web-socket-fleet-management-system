# KMS Customer Managed Key for DynamoDB encryption at rest
resource "aws_kms_key" "this" {
  description             = "${var.app}-${var.env}-${var.name} DynamoDB encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}-kms"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.app}-${var.env}-${var.name}"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_dynamodb_table" "this" {
  name         = "${var.app}-${var.env}-${var.name}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = var.partition_key
  range_key    = var.sort_key

  # CKV_AWS_119: Encrypt with a KMS Customer Managed CMK
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.this.arn
  }

  # CKV_AWS_28: Enable point-in-time recovery (backup)
  point_in_time_recovery {
    enabled = true
  }

  attribute {
    name = var.partition_key
    type = "S"
  }

  dynamic "attribute" {
    for_each = var.sort_key != null ? [1] : []
    content {
      name = var.sort_key
      type = "S"
    }
  }

  dynamic "attribute" {
    for_each = var.gsi_config != null ? [1] : []
    content {
      name = var.gsi_config.hash_key
      type = "S"
    }
  }

  dynamic "attribute" {
    for_each = var.gsi_config != null ? [1] : []
    content {
      name = var.gsi_config.range_key
      type = "N"
    }
  }

  dynamic "global_secondary_index" {
    for_each = var.gsi_config != null ? [1] : []
    content {
      name            = var.gsi_config.name
      hash_key        = var.gsi_config.hash_key
      range_key       = var.gsi_config.range_key
      projection_type = var.gsi_config.projection_type
    }
  }

  dynamic "ttl" {
    for_each = var.ttl_enabled ? [1] : []
    content {
      enabled        = true
      attribute_name = var.ttl_attribute
    }
  }

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}"
    Environment = var.env
    Application = var.app
  }
}
