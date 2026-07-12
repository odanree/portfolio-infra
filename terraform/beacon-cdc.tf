# Beacon CDC listener on AWS Fargate — ADR-021 phase 3b.
#
# Purpose:
#   Runs the beacon-mcp CDC listener (LISTEN rag_stale) as an always-on
#   Fargate task. Catches NOTIFY events fired by Postgres triggers on
#   Beacon's projects + experiences tables (job-search-pipeline#212),
#   debounces bursts on a 10-second window, then POSTs to a Vercel
#   Deploy Hook that rebuilds the ai-chatbot's RAG index from Beacon
#   (ai-chatbot#62 wired the vercel-build script).
#
# Why Fargate and not Lambda:
#   LISTEN/NOTIFY holds a persistent Postgres connection. Lambda's
#   request-response model doesn't map to that shape — you'd end up
#   polling pg_notification_queue_usage() on a schedule, which
#   defeats the point. Fargate gives you always-on compute with the
#   operational simplicity of a container.
#
# Why Fargate Spot:
#   The workload is restart-tolerant (debounce buffer + reconnect
#   logic). Spot cuts cost ~70%. If AWS reclaims capacity, ECS
#   restarts the task; NOTIFYs delivered during the ~30-90 s outage
#   are the acceptable cost for the price cut. Higher-availability
#   deployments (multi-region, etc.) are out of scope per ADR-021.
#
# Bootstrap order:
#   1. `terraform apply` creates the ECR repo, secrets shells, IAM
#      roles, log group, cluster, service (with desiredCount=0
#      initially because there's no image yet).
#   2. Operator populates secrets out-of-band with
#      `aws secretsmanager put-secret-value`.
#   3. beacon-mcp CI (ADR-021 phase 3c, follow-up PR) builds the
#      listener image and pushes to ECR on merge to master.
#   4. Operator sets desiredCount=1 (or `terraform apply` with the
#      `cdc_listener_desired_count` variable flipped to 1) once
#      the image is in ECR.

# ─── ECR ─────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "beacon_cdc_listener" {
  name                 = "${var.tag_name}/beacon-cdc-listener"
  image_tag_mutability = "MUTABLE" # `latest` moves; version tags stay pinned

  image_scanning_configuration {
    scan_on_push = true # scans against ECR's built-in vulnerability DB
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "beacon_cdc_listener" {
  repository = aws_ecr_repository.beacon_cdc_listener.name

  # Keep last 10 tagged images + drop untagged after 1 day. Enough
  # history for rollback; not enough to accumulate cost.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPatternList = ["*"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Drop untagged after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ─── Secrets Manager entries (values populated out-of-band) ──────────

resource "aws_secretsmanager_secret" "beacon_cdc_database_url" {
  name                    = "${var.tag_name}/beacon-cdc-database-url"
  description             = "Raw asyncpg URL for Beacon Postgres — used by the CDC listener to LISTEN rag_stale. postgresql://user:pw@127.0.0.1:15433/db (127.0.0.1 because autossh tunnels remote 15433 to container's local 15433)."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "beacon_cdc_ssh_key" {
  name                    = "${var.tag_name}/beacon-cdc-ssh-key"
  description             = "PEM-encoded SSH private key for autossh → Hetzner VPS root@65.108.243.192. Passphrase-less; store as SecretString verbatim (newlines preserved). Rotate by generating a new key, populating this secret, and appending the pubkey to the VPS ~/.ssh/authorized_keys BEFORE removing the old one."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "beacon_cdc_vercel_deploy_hook" {
  name                    = "${var.tag_name}/beacon-cdc-vercel-deploy-hook"
  description             = "Vercel Deploy Hook URL for ai-chatbot main branch. Grab from Vercel dashboard → project settings → Git → Deploy Hooks. URL IS the auth token — treat as a secret even though it's just a URL."
  recovery_window_in_days = 0
}

# ─── IAM: task execution role (Fargate agent side) ──────────────────
# The execution role is what ECS assumes to pull the image from ECR,
# fetch secrets, and write logs. It runs BEFORE the task container
# starts. Standard managed policy covers ECR + CloudWatch Logs; a
# scoped inline policy grants read on our specific secrets.

data "aws_iam_policy_document" "cdc_assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cdc_task_execution" {
  name               = "${var.tag_name}-cdc-task-execution"
  assume_role_policy = data.aws_iam_policy_document.cdc_assume_ecs_tasks.json
}

resource "aws_iam_role_policy_attachment" "cdc_task_execution_managed" {
  role       = aws_iam_role.cdc_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "cdc_secrets_read" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    # Wildcard suffix accommodates AWS's per-version ARN scheme
    # (secret:name-abc123) — the exact suffix isn't known ahead of time.
    resources = [
      "${aws_secretsmanager_secret.beacon_cdc_database_url.arn}*",
      "${aws_secretsmanager_secret.beacon_cdc_ssh_key.arn}*",
      "${aws_secretsmanager_secret.beacon_cdc_vercel_deploy_hook.arn}*",
    ]
  }
}

resource "aws_iam_role_policy" "cdc_secrets_read" {
  name   = "${var.tag_name}-cdc-secrets-read"
  role   = aws_iam_role.cdc_task_execution.id
  policy = data.aws_iam_policy_document.cdc_secrets_read.json
}

# ─── IAM: task role (container-side workload identity) ──────────────
# The task role is what code INSIDE the container assumes for AWS API
# calls. The listener doesn't make any AWS API calls at runtime (it
# talks to Postgres via the tunnel and Vercel via HTTPS), so this
# role has NO policies attached. Kept as a distinct role for future
# extension (e.g. writing CloudWatch metrics directly, or fetching
# additional secrets at runtime rather than via env injection).

resource "aws_iam_role" "cdc_task" {
  name               = "${var.tag_name}-cdc-task"
  assume_role_policy = data.aws_iam_policy_document.cdc_assume_ecs_tasks.json
}

# ─── CloudWatch Log Group ──────────────────────────────────────────

resource "aws_cloudwatch_log_group" "cdc_listener" {
  name              = "/ecs/${var.tag_name}-cdc-listener"
  retention_in_days = 7
}

# ─── Security group ────────────────────────────────────────────────
# Egress-only: outbound HTTPS (to Secrets Manager, ECR, Vercel), plus
# outbound SSH to Hetzner for the tunnel. No ingress — the listener
# is a pure consumer.

resource "aws_security_group" "cdc_listener" {
  name        = "${var.tag_name}-cdc-listener-sg"
  description = "beacon-cdc-listener Fargate task: outbound only (HTTPS + SSH to Hetzner)"
  vpc_id      = data.aws_vpc.default.id

  # Egress: HTTPS to Vercel + ECR + Secrets Manager
  egress {
    description = "HTTPS (Vercel Deploy Hook, ECR image pull, Secrets Manager)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress: SSH to Hetzner Beacon VPS for autossh tunnel
  egress {
    description = "SSH to Hetzner VPS (autossh tunnel for Beacon Postgres)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    # Locked to the Hetzner VPS IP. If it ever changes, rotate here.
    cidr_blocks = ["65.108.243.192/32"]
  }

  # Egress: DNS
  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.tag_name}-cdc-listener-sg"
  }
}

# ─── ECS cluster + Fargate capacity provider ───────────────────────

resource "aws_ecs_cluster" "cdc" {
  name = "${var.tag_name}-cdc"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "cdc" {
  cluster_name       = aws_ecs_cluster.cdc.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }
}

# ─── Task definition ───────────────────────────────────────────────

resource "aws_ecs_task_definition" "cdc_listener" {
  family                   = "${var.tag_name}-cdc-listener"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"  # 0.25 vCPU
  memory                   = "512"  # 512 MB — measured RSS ~40 MB, plenty of headroom
  execution_role_arn       = aws_iam_role.cdc_task_execution.arn
  task_role_arn            = aws_iam_role.cdc_task.arn

  container_definitions = jsonencode([
    {
      name  = "listener"
      image = "${aws_ecr_repository.beacon_cdc_listener.repository_url}:${var.cdc_listener_image_tag}"
      essential = true

      # Fargate injects these at container start by fetching from
      # Secrets Manager. Values never touch Terraform state.
      secrets = [
        {
          name      = "BEACON_DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.beacon_cdc_database_url.arn
        },
        {
          name      = "SSH_PRIVATE_KEY"
          valueFrom = aws_secretsmanager_secret.beacon_cdc_ssh_key.arn
        },
        {
          name      = "VERCEL_DEPLOY_HOOK_URL"
          valueFrom = aws_secretsmanager_secret.beacon_cdc_vercel_deploy_hook.arn
        },
      ]

      # Non-secret config — knobs the operator might want to tune per
      # environment without rewriting the Terraform.
      environment = [
        { name = "RAG_REFRESH_MODE",     value = "webhook" },
        { name = "RAG_DEBOUNCE_SECONDS", value = "10" },
        { name = "LOG_LEVEL",            value = "INFO" },
        # SSH_TUNNEL_HOST and SSH_TUNNEL_FORWARD are baked into the
        # image as defaults — override here only if pointing at a
        # non-prod Beacon.
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.cdc_listener.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "listener"
        }
      }

      # No portMappings — this container doesn't accept inbound.
      # No healthCheck at the container level — ECS-level health via
      # the service's minimumHealthyPercent + task exit code is enough
      # for a single-task always-on service.
    }
  ])
}

# ─── Service ───────────────────────────────────────────────────────

resource "aws_ecs_service" "cdc_listener" {
  name            = "${var.tag_name}-cdc-listener"
  cluster         = aws_ecs_cluster.cdc.id
  task_definition = aws_ecs_task_definition.cdc_listener.arn
  desired_count   = var.cdc_listener_desired_count
  launch_type     = null # capacity provider strategy below overrides

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.cdc_listener.id]
    assign_public_ip = true # required in default VPC for ECR image pull + outbound SSH
  }

  deployment_minimum_healthy_percent = 0   # single task; take it down before bringing new one up
  deployment_maximum_percent         = 200 # allow rolling deploy to overlap briefly

  # When the operator updates cdc_listener_image_tag, force a fresh
  # task rather than trying to reuse the previous one.
  force_new_deployment = true

  lifecycle {
    ignore_changes = [
      # Avoid churn when operator manually scales via AWS console
      desired_count,
    ]
  }
}
