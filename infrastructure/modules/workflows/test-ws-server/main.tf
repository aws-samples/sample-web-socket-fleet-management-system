data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# KMS key for ECR image encryption
resource "aws_kms_key" "ecr" {
  # checkov:skip=CKV2_AWS_64: POC — relying on default KMS key policy (account root access). Explicit least-privilege policy deferred.
  description             = "${var.app}-${var.env}-test-ws-server ECR encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name        = "${var.app}-${var.env}-test-ws-server-ecr-kms"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.app}-${var.env}-test-ws-server-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

# ECR Repository for the test WS server
resource "aws_ecr_repository" "test_ws_server" {
  name                 = "${var.app}-${var.env}-test-ws-server"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # CKV_AWS_136: Encrypt repository images using KMS
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = {
    Name        = "${var.app}-${var.env}-test-ws-server"
    Environment = var.env
    Application = var.app
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "test_ws_server" {
  name = "/ecs/${var.app}-${var.env}-test-ws-server"
  # CKV_AWS_338: Retain logs for at least 1 year
  retention_in_days = 365

  tags = {
    Name        = "${var.app}-${var.env}-test-ws-server-logs"
    Environment = var.env
    Application = var.app
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "test_ws_server" {
  family                   = "${var.app}-${var.env}-test-ws-server"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = var.ecs_task_execution_role_arn

  container_definitions = jsonencode([
    {
      name      = "test-ws-server"
      image     = "${aws_ecr_repository.test_ws_server.repository_url}:latest"
      essential = true

      # CKV_AWS_336: Limit the container to a read-only root filesystem
      readonlyRootFilesystem = true

      portMappings = [
        { containerPort = 8765, protocol = "tcp" },
        { containerPort = 8766, protocol = "tcp" }
      ]

      environment = [
        { name = "WS_PORT", value = "8765" },
        { name = "HTTP_PORT", value = "8766" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.test_ws_server.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "test-ws-server"
        }
      }
    }
  ])

  tags = {
    Name        = "${var.app}-${var.env}-test-ws-server"
    Environment = var.env
    Application = var.app
  }
}

# ECS Service — runs exactly 1 task with a stable private IP via Cloud Map
resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "${var.app}-${var.env}.local"
  description = "Service discovery namespace for test WS server"
  vpc         = var.vpc_id

  tags = {
    Name        = "${var.app}-${var.env}-namespace"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_service_discovery_service" "test_ws_server" {
  name = "test-ws-server"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name        = "${var.app}-${var.env}-test-ws-server-sd"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_ecs_service" "test_ws_server" {
  name            = "${var.app}-${var.env}-test-ws-server-svc"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.test_ws_server.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # CKV_AWS_333: runs in private subnets with egress via NAT; no public IP
  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.test_ws_server.arn
  }

  tags = {
    Name        = "${var.app}-${var.env}-test-ws-server-svc"
    Environment = var.env
    Application = var.app
  }
}

# Build and push Docker image
resource "null_resource" "build_and_push" {
  depends_on = [aws_ecr_repository.test_ws_server]

  triggers = {
    repository_url = aws_ecr_repository.test_ws_server.repository_url
    source_hash    = sha256(join("", [for f in fileset("${path.root}/../src/test-ws-server", "**") : filesha256("${path.root}/../src/test-ws-server/${f}")]))
  }

  provisioner "local-exec" {
    command     = "${path.module}/build-and-push.sh"
    working_dir = path.root
    environment = {
      AWS_REGION     = data.aws_region.current.name
      AWS_ACCOUNT_ID = data.aws_caller_identity.current.account_id
      REPO_NAME      = aws_ecr_repository.test_ws_server.name
      REPO_URL       = aws_ecr_repository.test_ws_server.repository_url
      SOURCE_PATH    = "${path.root}/../src/test-ws-server"
      IMAGE_TAG      = substr(self.triggers.source_hash, 0, 8)
    }
  }
}
