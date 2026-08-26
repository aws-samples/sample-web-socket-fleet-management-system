output "api_gateway_url" {
  description = "API Gateway endpoint URL"
  value       = module.api_gateway.api_url
  sensitive   = true
}

output "connections_table_name" {
  description = "DynamoDB connections table name"
  value       = module.connections_table.table_name
  sensitive   = true
}

output "work_queue_url" {
  description = "SQS work queue URL"
  value       = module.work_queue.queue_url
  sensitive   = true
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs_worker.cluster_name
  sensitive   = true
}

output "ecr_repository_url" {
  description = "ECR repository URL for worker image"
  value       = module.ecs_worker.ecr_repository_url
  sensitive   = true
}

output "test_ws_server_url" {
  description = "WebSocket URL for the test transcript server (use as ws_url in START events)"
  value       = module.test_ws_server.ws_url
  sensitive   = true
}

output "test_ws_server_ecr_url" {
  description = "ECR repository URL for the test WS server image"
  value       = module.test_ws_server.ecr_repository_url
}
