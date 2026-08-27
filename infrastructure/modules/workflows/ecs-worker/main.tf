data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# VPC and Networking
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.app}-${var.env}-vpc"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name        = "${var.app}-${var.env}-igw"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name        = "${var.app}-${var.env}-public-rt"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true
  availability_zone       = "${data.aws_region.current.name}${count.index == 0 ? "a" : "b"}"

  tags = {
    Name        = "${var.app}-${var.env}-public-${count.index}"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private subnets for ECS tasks (no public IPs). Outbound internet is via NAT.
resource "aws_subnet" "private" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 100)
  availability_zone = "${data.aws_region.current.name}${count.index == 0 ? "a" : "b"}"

  tags = {
    Name        = "${var.app}-${var.env}-private-${count.index}"
    Environment = var.env
    Application = var.app
  }
}

# NAT gateway (one, in the first public subnet) for private-subnet egress
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "${var.app}-${var.env}-nat-eip"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.this]

  tags = {
    Name        = "${var.app}-${var.env}-nat"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name        = "${var.app}-${var.env}-private-rt"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Security Group
resource "aws_security_group" "ecs" {
  name        = "${var.app}-${var.env}-ecs-sg"
  description = "ECS tasks outbound"
  vpc_id      = aws_vpc.this.id

  # Allow tasks in this SG to talk to each other (for test WS server)
  ingress {
    from_port   = 8765
    to_port     = 8766
    protocol    = "tcp"
    self        = true
    description = "Allow ECS tasks to reach test WS server"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.app}-${var.env}-ecs-sg"
    Environment = var.env
    Application = var.app
  }
}

# KMS key for ECR image encryption
resource "aws_kms_key" "ecr" {
  # checkov:skip=CKV2_AWS_64: POC — relying on default KMS key policy (account root access). Explicit least-privilege policy deferred.
  description             = "${var.app}-${var.env}-worker ECR encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name        = "${var.app}-${var.env}-ecr-kms"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.app}-${var.env}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

# ECR Repository
resource "aws_ecr_repository" "worker" {
  name                 = "${var.app}-${var.env}-worker"
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
    Name        = "${var.app}-${var.env}-worker"
    Environment = var.env
    Application = var.app
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "this" {
  name = "${var.app}-${var.env}-cluster"

  tags = {
    Name        = "${var.app}-${var.env}-cluster"
    Environment = var.env
    Application = var.app
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "worker" {
  name = "/ecs/${var.app}-${var.env}-worker"
  # CKV_AWS_338: Retain logs for at least 1 year
  retention_in_days = 365

  tags = {
    Name        = "${var.app}-${var.env}-worker-logs"
    Environment = var.env
    Application = var.app
  }
}

# IAM Roles
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.app}-${var.env}-ecs-task-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.app}-${var.env}-ecs-task-exec-role"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_managed" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "${var.app}-${var.env}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.app}-${var.env}-ecs-task-role"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_iam_policy" "ecs_task_policy" {
  name = "${var.app}-${var.env}-ecs-task-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          var.table_arn,
          var.gsi_arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = var.messages_table_arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = var.queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [
          var.table_kms_key_arn,
          var.messages_table_kms_key_arn
        ]
      }
    ]
  })

  tags = {
    Name        = "${var.app}-${var.env}-ecs-task-policy"
    Environment = var.env
    Application = var.app
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_custom" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.ecs_task_policy.arn
}

# ECS Task Definition
resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.app}-${var.env}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = "${aws_ecr_repository.worker.repository_url}:latest"
      essential = true

      # CKV_AWS_336: Limit the container to a read-only root filesystem
      readonlyRootFilesystem = true

      environment = [
        { name = "TABLE_NAME", value = var.table_name },
        { name = "MESSAGES_TABLE_NAME", value = var.messages_table_name },
        { name = "QUEUE_URL", value = var.queue_url },
        { name = "GSI_NAME", value = var.gsi_name },
        { name = "LEASE_SECONDS", value = "20" },
        { name = "HEARTBEAT_EVERY", value = "5" },
        { name = "MAX_CONNECTIONS", value = "800" },
        { name = "RECONCILE_EVERY", value = "60" },
        { name = "RECONCILE_PAGE_SIZE", value = "50" },
        { name = "SERVICE_NAME", value = var.service_name_dimension },
        # Off by default to avoid logging user/PII message content to CloudWatch.
        { name = "LOG_MESSAGE_CONTENT", value = "false" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.worker.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "worker"
        }
      }

      stopTimeout = 60
    }
  ])

  tags = {
    Name        = "${var.app}-${var.env}-worker"
    Environment = var.env
    Application = var.app
  }
}

# ECS Service
resource "aws_ecs_service" "worker" {
  name            = "${var.app}-${var.env}-worker-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # CKV_AWS_333: tasks run in private subnets with egress via NAT; no public IP
  network_configuration {
    subnets          = [for s in aws_subnet.private : s.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  tags = {
    Name        = "${var.app}-${var.env}-worker-svc"
    Environment = var.env
    Application = var.app
  }
}

# Auto-build and push Docker image
resource "null_resource" "build_and_push" {
  depends_on = [aws_ecr_repository.worker]

  triggers = {
    repository_url = aws_ecr_repository.worker.repository_url
    source_hash    = sha256(join("", [for f in fileset("${path.root}/../src/worker", "**") : filesha256("${path.root}/../src/worker/${f}")]))
  }

  provisioner "local-exec" {
    command     = "${path.module}/build-and-push.sh"
    working_dir = path.root
    environment = {
      AWS_REGION     = data.aws_region.current.name
      AWS_ACCOUNT_ID = data.aws_caller_identity.current.account_id
      REPO_NAME      = aws_ecr_repository.worker.name
      REPO_URL       = aws_ecr_repository.worker.repository_url
      SOURCE_PATH    = "${path.root}/../src/worker"
      IMAGE_TAG      = substr(self.triggers.source_hash, 0, 8)
    }
  }
}

# Auto Scaling
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "scale_on_active_connections" {
  name               = "${var.app}-${var.env}-scale-active-connections"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 700
    scale_in_cooldown  = 900
    scale_out_cooldown = 120

    customized_metric_specification {
      metric_name = "ActiveConnections"
      namespace   = "WsFleet"
      statistic   = "Average"
      unit        = "Count"

      dimensions {
        name  = "ServiceName"
        value = var.service_name_dimension
      }
    }
  }
}
