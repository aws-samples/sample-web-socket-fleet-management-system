output "service_discovery_name" {
  description = "DNS name for the test WS server (use as ws_url for workers)"
  value       = "test-ws-server.${var.app}-${var.env}.local"
}

output "ws_url" {
  description = "Full WebSocket URL workers should connect to"
  value       = "ws://test-ws-server.${var.app}-${var.env}.local:8765"
}

output "ecr_repository_url" {
  description = "ECR repository URL for the test WS server image"
  value       = aws_ecr_repository.test_ws_server.repository_url
}
