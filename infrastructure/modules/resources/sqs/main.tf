resource "aws_sqs_queue" "this" {
  name                       = "${var.app}-${var.env}-${var.name}"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  # CKV_AWS_27: Encrypt data at rest. SSE-SQS (SQS-owned key) requires no key
  # management; switch to a CMK by setting kms_master_key_id if required.
  sqs_managed_sse_enabled = true

  tags = {
    Name        = "${var.app}-${var.env}-${var.name}"
    Environment = var.env
    Application = var.app
  }
}
