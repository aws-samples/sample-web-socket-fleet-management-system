data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "config" {
  name = var.ssm_config_path
}

locals {
  config = jsondecode(data.aws_ssm_parameter.config.value)

  app                    = local.config.app
  environment            = local.config.environment
  service_name_dimension = local.config.service_name_dimension
  # Secure-by-default: only disable auth if the config explicitly sets it to false.
  enable_api_auth     = try(local.config.enable_api_auth, true)
  api_key             = local.config.api_key
  ecs_desired_count   = local.config.ecs_desired_count
  ecs_min_capacity    = local.config.ecs_min_capacity
  ecs_max_capacity    = local.config.ecs_max_capacity
  worker_cpu          = local.config.worker_cpu
  worker_memory       = local.config.worker_memory
  vpc_cidr            = local.config.vpc_cidr
  public_subnet_cidrs = local.config.public_subnet_cidrs

  common_tags = {
    Application = local.app
    Environment = local.environment
    ManagedBy   = "Terraform"
  }
}

# 1. DynamoDB Table for Connection State
module "connections_table" {
  source = "./modules/resources/dynamodb"

  name          = "connections"
  partition_key = "pk"
  app           = local.app
  env           = local.environment

  gsi_config = {
    name            = "gsi_state_lease"
    hash_key        = "desired_state"
    range_key       = "lease_expires_at_ms"
    projection_type = "KEYS_ONLY"
  }
}

# 1b. DynamoDB Table for storing transcript messages
module "messages_table" {
  source = "./modules/resources/dynamodb"

  name          = "messages"
  partition_key = "pk"
  sort_key      = "sk"
  app           = local.app
  env           = local.environment
  ttl_enabled   = true
  ttl_attribute = "ttl"

  gsi_config = null
}

# 2. SQS Queue for Work Distribution
module "work_queue" {
  source = "./modules/resources/sqs"

  name                       = "work-queue"
  app                        = local.app
  env                        = local.environment
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
}

# 3. Lambda Event Router
module "event_router_lambda" {
  source = "./modules/resources/lambda"

  name        = "event-router"
  app         = local.app
  env         = local.environment
  runtime     = "python3.11"
  handler     = "app.handler"
  source_dir  = "${path.module}/../src/lambda/event_router"
  timeout     = 30
  memory_size = 256

  environment_variables = {
    TABLE_NAME = module.connections_table.table_name
    QUEUE_URL  = module.work_queue.queue_url
  }

  policy_statements = [
    {
      effect = "Allow"
      actions = [
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:GetItem"
      ]
      resources = [module.connections_table.table_arn]
    },
    {
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = [module.work_queue.queue_arn]
    },
    {
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [module.connections_table.kms_key_arn]
    }
  ]
}

# 3b. API Authorizer Lambda
module "api_authorizer_lambda" {
  source = "./modules/resources/lambda"

  name        = "api-authorizer"
  app         = local.app
  env         = local.environment
  runtime     = "python3.11"
  handler     = "app.handler"
  source_dir  = "${path.module}/../src/lambda/authorizer"
  timeout     = 5
  memory_size = 128

  environment_variables = {
    API_KEY = local.api_key
  }

  policy_statements = []
}

# 4. API Gateway for Event Ingestion
module "api_gateway" {
  source = "./modules/workflows/api-gateway"

  name                 = "ws-fleet-api"
  app                  = local.app
  env                  = local.environment
  lambda_invoke_arn    = module.event_router_lambda.invoke_arn
  lambda_function_name = module.event_router_lambda.function_name

  enable_auth                     = local.enable_api_auth
  authorizer_lambda_invoke_arn    = module.api_authorizer_lambda.invoke_arn
  authorizer_lambda_function_name = module.api_authorizer_lambda.function_name
}

# 5. ECS Worker Service
module "ecs_worker" {
  source = "./modules/workflows/ecs-worker"

  app                 = local.app
  env                 = local.environment
  vpc_cidr            = local.vpc_cidr
  public_subnet_cidrs = local.public_subnet_cidrs

  worker_cpu    = local.worker_cpu
  worker_memory = local.worker_memory
  desired_count = local.ecs_desired_count
  min_capacity  = local.ecs_min_capacity
  max_capacity  = local.ecs_max_capacity

  table_name                 = module.connections_table.table_name
  table_arn                  = module.connections_table.table_arn
  messages_table_name        = module.messages_table.table_name
  messages_table_arn         = module.messages_table.table_arn
  table_kms_key_arn          = module.connections_table.kms_key_arn
  messages_table_kms_key_arn = module.messages_table.kms_key_arn
  gsi_arn                    = module.connections_table.gsi_arn
  queue_url                  = module.work_queue.queue_url
  queue_arn                  = module.work_queue.queue_arn
  gsi_name                   = "gsi_state_lease"

  service_name_dimension = local.service_name_dimension
}

# 6. Test WebSocket Server (transcript streaming endpoint for workers)
module "test_ws_server" {
  source = "./modules/workflows/test-ws-server"

  app = local.app
  env = local.environment

  vpc_id                      = module.ecs_worker.vpc_id
  cluster_id                  = module.ecs_worker.cluster_id
  subnet_ids                  = module.ecs_worker.subnet_ids
  security_group_id           = module.ecs_worker.security_group_id
  ecs_task_execution_role_arn = module.ecs_worker.ecs_task_execution_role_arn
}
