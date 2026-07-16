# Beacon scoring pipeline on AWS — ADR-020 phase 1.
#
# Purpose:
#   Strangler-fig migration of job-search-pipeline Phase 3 (dual scoring —
#   Haiku triage + Sonnet depth for high-triage jobs) off Celery on Hetzner
#   onto an AWS-native event-driven pipeline. Beacon API enqueues a job to
#   the scoring SQS queue; EventBridge Pipes fans it into a Step Functions
#   Standard state machine; the state machine invokes HaikuTriage, decides
#   on the composite score whether to run SonnetDepth, then calls back to
#   the Beacon API with an HMAC-signed POST that lands the result in the
#   existing write path (preserving the LISTEN/NOTIFY trigger surface).
#
# What this file provisions:
#   - 1× ECR repo (backs both scoring lambdas; distinguished at runtime by
#     the LAMBDA_ROLE env var passed to the container entrypoint)
#   - 4× Secrets Manager entries (Anthropic key, HMAC callback secret,
#     Beacon callback URL, Beacon-side scoring bearer token for the
#     internal callback endpoint)
#   - 2× SQS queues (beacon-score-requests + DLQ; maxReceiveCount=3)
#   - IAM: Lambda execution role, Step Functions execution role, Pipe role
#   - CloudWatch Log Groups for both lambdas + the state machine
#   - 3× Lambda functions (HaikuTriage, SonnetDepth, PostToBeaconAPI —
#     gated on var.scoring_enabled to allow first-apply bootstrap without
#     images in ECR yet)
#   - 1× Step Functions Standard state machine (also gated)
#   - 1× EventBridge Pipe wiring SQS → Step Functions (also gated)
#
# Named patterns:
#   Strangler-fig migration; event-driven ingest via SQS; declarative
#   retry policy with exponential backoff in the state machine JSON;
#   fan-in decision node (TriageChoice); dead-letter queue for poison
#   messages; callback-URL pattern with HMAC verification at the trust
#   boundary. See ADR-020 for the full topology + decision log.
#
# Region note:
#   ADR-020 mentioned us-west-2 aspirationally to match old PCT stack.
#   Everything in this account (Marquez, beacon-cdc) runs in us-east-1;
#   putting scoring in us-east-1 keeps the operational surface single-
#   region and avoids cross-region secrets/log-group juggling. Callback
#   latency to Hetzner (~140 ms) dominates over any AWS-region delta.
#
# Bootstrap order:
#   1. `terraform apply` with scoring_enabled=false — creates ECR, SQS,
#      DLQ, IAM shells, secrets shells, log groups. Lambda + Step
#      Functions + Pipe skipped because there's no image yet.
#   2. Operator populates all 4 secrets via
#      `aws secretsmanager put-secret-value`.
#   3. beacon-scoring CI (follow-up work under job-search-pipeline)
#      builds the container image (single image, entrypoint dispatches
#      on LAMBDA_ROLE) and pushes to ECR on merge to master.
#   4. `terraform apply -var scoring_enabled=true` — brings up the
#      three lambdas, the state machine, and the SQS→SFN Pipe.
#   5. Flip Beacon's SCORING_BACKEND flag to `stepfunctions` for 10%
#      of traffic (ADR-020 phase 3) and start comparing outputs via
#      the parity harness.

locals {
  scoring_name = "${var.tag_name}-beacon-scoring"

  # Same container image, three "roles" — the entrypoint reads
  # LAMBDA_ROLE and dispatches to the right handler. Cheaper to build
  # + push one image than three, and keeps the Anthropic SDK layer
  # cache-friendly.
  scoring_lambda_roles = {
    haiku_triage   = { timeout = 30, memory = 512 }
    sonnet_depth   = { timeout = 60, memory = 1024 }
    post_to_beacon = { timeout = 15, memory = 256 }
  }
}

# ─── ECR ─────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "beacon_scoring" {
  name                 = "${var.tag_name}/beacon-scoring"
  image_tag_mutability = "MUTABLE" # `latest` moves; version tags stay pinned

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "beacon_scoring" {
  repository = aws_ecr_repository.beacon_scoring.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
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

# ─── Secrets Manager (values populated out-of-band) ─────────────────

resource "aws_secretsmanager_secret" "scoring_anthropic_key" {
  name                    = "${local.scoring_name}/anthropic-api-key"
  description             = "Anthropic API key for the scoring lambdas. Same account, distinct key for spend attribution vs the Beacon Celery worker (see project_anthropic_key_attribution.md). Rotate by generating a new key in console.anthropic.com, populating this secret, then revoking the old key."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "scoring_callback_hmac" {
  name                    = "${local.scoring_name}/callback-hmac-key"
  description             = "Shared HMAC secret used by the PostToBeaconAPI lambda to sign requests to POST /api/internal/scoring-result and by Beacon to verify them. Rotate by generating a new key (openssl rand -hex 32), populating this secret AND Beacon's SCORING_CALLBACK_HMAC_KEY env var in the same deploy window."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "scoring_callback_url" {
  name                    = "${local.scoring_name}/callback-url"
  description             = "Fully-qualified URL of Beacon's scoring callback endpoint, e.g. https://beacon.danhle.net/api/internal/scoring-result. Stored as a secret because it identifies the internal endpoint; not sensitive on its own but easy to change here without redeploying the lambda."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "scoring_callback_bearer" {
  name                    = "${local.scoring_name}/callback-bearer-token"
  description             = "Bearer token added as a defense-in-depth check on the Beacon callback endpoint alongside HMAC. Belt-and-suspenders: HMAC proves the payload wasn't tampered with; the bearer proves the caller has current shared-secret material. Rotate on the same schedule as the HMAC key."
  recovery_window_in_days = 0
}

# ─── SQS: request queue + DLQ ────────────────────────────────────────

resource "aws_sqs_queue" "scoring_dlq" {
  name = "${local.scoring_name}-dlq"

  # DLQ retention is longer than the main queue so a human has a
  # week to inspect + reprocess poison payloads before AWS drops them.
  message_retention_seconds = 1209600 # 14 days (SQS max)
}

resource "aws_sqs_queue" "scoring_requests" {
  name = "${local.scoring_name}-requests"

  # Visibility timeout must exceed the longest possible state machine
  # execution or Pipes will re-deliver mid-flight. Sonnet worst-case is
  # ~30 s incl. cold start + retries; 5 min gives comfortable headroom.
  #
  # Scaling caveat: worst-case time-to-DLQ = visibility_timeout ×
  # maxReceiveCount = 5 min × 3 = 15 min. Fine at ~50 scorings/day
  # because in-flight backlog is negligible; at >1k/day this timeout
  # starts to artificially throttle throughput on retry storms.
  # Revisit if daily volume climbs an order of magnitude.
  visibility_timeout_seconds = 300

  # 4 days — long enough for a weekend outage to not lose messages,
  # short enough that a chronically broken pipeline doesn't accumulate
  # tens of thousands of stale scoring requests.
  message_retention_seconds = 345600

  # Poison-message threshold: after 3 receive attempts, message
  # graduates to the DLQ instead of endlessly re-entering the pipeline.
  # Matches the ADR-020 Step Functions retry policy (3 attempts inside
  # the state machine + 3 SQS deliveries = 9 total attempts before DLQ,
  # which is intentional — most transients clear in 1–2, and anything
  # still failing at 9 is a real bug worth human review).
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.scoring_dlq.arn
    maxReceiveCount     = 3
  })
}

# ─── CloudWatch Log Groups ──────────────────────────────────────────

resource "aws_cloudwatch_log_group" "scoring_lambda" {
  for_each = local.scoring_lambda_roles

  # Lambda auto-creates log groups on first invocation if they don't
  # exist, but managing them in Terraform pins retention (default is
  # "never expire" = quiet cost bleed) and makes the IAM policy easy.
  name              = "/aws/lambda/${local.scoring_name}-${replace(each.key, "_", "-")}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "scoring_state_machine" {
  # Step Functions requires the /aws/vendedlogs/states/ prefix for
  # log delivery to work without extra permissions.
  name              = "/aws/vendedlogs/states/${local.scoring_name}-pipeline"
  retention_in_days = 7
}

# ─── IAM: Lambda execution role ─────────────────────────────────────
# One role shared by all three lambdas — they need the same permissions
# (secrets read, CloudWatch logs write). Distinct per-lambda roles would
# be tighter security but overkill at portfolio scale.

data "aws_iam_policy_document" "scoring_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scoring_lambda" {
  name               = "${local.scoring_name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.scoring_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "scoring_lambda_basic" {
  role       = aws_iam_role.scoring_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "scoring_lambda_secrets" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "${aws_secretsmanager_secret.scoring_anthropic_key.arn}*",
      "${aws_secretsmanager_secret.scoring_callback_hmac.arn}*",
      "${aws_secretsmanager_secret.scoring_callback_url.arn}*",
      "${aws_secretsmanager_secret.scoring_callback_bearer.arn}*",
    ]
  }
}

resource "aws_iam_role_policy" "scoring_lambda_secrets" {
  name   = "${local.scoring_name}-lambda-secrets"
  role   = aws_iam_role.scoring_lambda.id
  policy = data.aws_iam_policy_document.scoring_lambda_secrets.json
}

# ─── IAM: Step Functions execution role ─────────────────────────────

data "aws_iam_policy_document" "scoring_sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scoring_sfn" {
  name               = "${local.scoring_name}-sfn"
  assume_role_policy = data.aws_iam_policy_document.scoring_sfn_assume.json
}

data "aws_iam_policy_document" "scoring_sfn_lambda_invoke" {
  # Prefix-scoped to ${local.scoring_name}-* rather than pinned to the
  # three explicit function ARNs. Two reasons:
  #   1. Explicit ARNs break the scoring_enabled=false bootstrap —
  #      the Lambda resources don't exist yet on first apply, so
  #      terraform can't materialize their ARNs into the policy.
  #   2. The prefix bounds blast radius: this role cannot invoke any
  #      Lambda outside the beacon-scoring namespace even if a future
  #      operator adds a fourth scoring lambda.
  # Trade-off: a security team would prefer explicit ARNs. At portfolio
  # scale the prefix boundary is a defensible compromise; at production
  # scale we'd split bootstrap into a separate plan phase and pin.
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:aws:lambda:${var.region}:*:function:${local.scoring_name}-*"]
  }
}

resource "aws_iam_role_policy" "scoring_sfn_lambda_invoke" {
  name   = "${local.scoring_name}-sfn-lambda-invoke"
  role   = aws_iam_role.scoring_sfn.id
  policy = data.aws_iam_policy_document.scoring_sfn_lambda_invoke.json
}

data "aws_iam_policy_document" "scoring_sfn_logs" {
  # Step Functions Standard needs these to deliver execution history
  # to CloudWatch Logs. Wildcarded per AWS docs — the log-delivery
  # subsystem creates resource-scoped grants at runtime.
  statement {
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "scoring_sfn_logs" {
  name   = "${local.scoring_name}-sfn-logs"
  role   = aws_iam_role.scoring_sfn.id
  policy = data.aws_iam_policy_document.scoring_sfn_logs.json
}

# ─── IAM: EventBridge Pipe role (SQS → SFN) ─────────────────────────

data "aws_iam_policy_document" "scoring_pipe_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scoring_pipe" {
  name               = "${local.scoring_name}-pipe"
  assume_role_policy = data.aws_iam_policy_document.scoring_pipe_assume.json
}

data "aws_iam_policy_document" "scoring_pipe_permissions" {
  # Source: read + delete from the request queue
  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.scoring_requests.arn]
  }

  # Target: start SFN execution. Wildcarded for bootstrap parity with
  # the lambda-invoke policy above.
  statement {
    actions   = ["states:StartExecution"]
    resources = ["arn:aws:states:${var.region}:*:stateMachine:${local.scoring_name}-*"]
  }
}

resource "aws_iam_role_policy" "scoring_pipe_permissions" {
  name   = "${local.scoring_name}-pipe-permissions"
  role   = aws_iam_role.scoring_pipe.id
  policy = data.aws_iam_policy_document.scoring_pipe_permissions.json
}

# ─── Lambda functions (gated on scoring_enabled) ────────────────────
# All three lambdas share:
#   - the same container image (dispatched via LAMBDA_ROLE)
#   - the same execution role
#   - the same secret injection (fetched at cold start, cached across
#     warm invocations by the handler)
# They differ only in timeout + memory (per local.scoring_lambda_roles).

resource "aws_lambda_function" "scoring" {
  for_each = var.scoring_enabled ? local.scoring_lambda_roles : {}

  function_name = "${local.scoring_name}-${replace(each.key, "_", "-")}"
  role          = aws_iam_role.scoring_lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.beacon_scoring.repository_url}:${var.scoring_lambda_image_tag}"
  timeout       = each.value.timeout
  memory_size   = each.value.memory

  environment {
    variables = {
      LAMBDA_ROLE                  = each.key
      ANTHROPIC_API_KEY_SECRET_ARN = aws_secretsmanager_secret.scoring_anthropic_key.arn
      CALLBACK_HMAC_SECRET_ARN     = aws_secretsmanager_secret.scoring_callback_hmac.arn
      CALLBACK_URL_SECRET_ARN      = aws_secretsmanager_secret.scoring_callback_url.arn
      CALLBACK_BEARER_SECRET_ARN   = aws_secretsmanager_secret.scoring_callback_bearer.arn
      LOG_LEVEL                    = "INFO"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.scoring_lambda[each.key].name
  }

  depends_on = [
    aws_iam_role_policy_attachment.scoring_lambda_basic,
    aws_iam_role_policy.scoring_lambda_secrets,
    aws_cloudwatch_log_group.scoring_lambda,
  ]
}

# ─── Step Functions Standard state machine (gated) ──────────────────
# Retry policy per ADR-020: 5 s initial interval, 2× backoff, 3 max
# attempts on transient errors (Anthropic 5xx, throttling, timeouts).
# Non-transient errors (schema validation, unrecoverable API errors)
# skip retries and go straight to HandleFailure → DLQ via the catch.

resource "aws_sfn_state_machine" "scoring" {
  count = var.scoring_enabled ? 1 : 0

  name     = "${local.scoring_name}-pipeline"
  role_arn = aws_iam_role.scoring_sfn.arn
  type     = "STANDARD"

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.scoring_state_machine.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  definition = jsonencode({
    Comment = "Beacon dual-scoring pipeline — ADR-020"
    StartAt = "HaikuTriage"
    States = {
      HaikuTriage = {
        Type     = "Task"
        Resource = aws_lambda_function.scoring["haiku_triage"].arn
        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException", "States.TaskFailed"]
            IntervalSeconds = 5
            BackoffRate     = 2
            MaxAttempts     = 3
          },
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "HandleFailure"
            ResultPath  = "$.error"
          },
        ]
        Next = "TriageChoice"
      }

      TriageChoice = {
        Type = "Choice"
        Choices = [
          {
            Variable           = "$.triage.composite_score"
            NumericGreaterThan = 4
            Next               = "SonnetDepth"
          },
        ]
        Default = "PostToBeaconAPI"
      }

      SonnetDepth = {
        Type     = "Task"
        Resource = aws_lambda_function.scoring["sonnet_depth"].arn
        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException", "States.TaskFailed"]
            IntervalSeconds = 5
            BackoffRate     = 2
            MaxAttempts     = 3
          },
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "HandleFailure"
            ResultPath  = "$.error"
          },
        ]
        Next = "PostToBeaconAPI"
      }

      PostToBeaconAPI = {
        Type     = "Task"
        Resource = aws_lambda_function.scoring["post_to_beacon"].arn
        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "States.TaskFailed"]
            IntervalSeconds = 5
            BackoffRate     = 2
            MaxAttempts     = 3
          },
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "HandleFailure"
            ResultPath  = "$.error"
          },
        ]
        End = true
      }

      HandleFailure = {
        # Fail the execution so Pipes propagates back to SQS; after
        # maxReceiveCount is exhausted, the original request lands in
        # the DLQ. HandleFailure runs no side effects itself — SQS
        # redrive is the DLQ mechanism, not a lambda write.
        Type  = "Fail"
        Error = "BeaconScoringFailure"
        Cause = "See CloudWatch execution history for stack trace"
      }
    }
  })

  depends_on = [
    aws_iam_role_policy.scoring_sfn_lambda_invoke,
    aws_iam_role_policy.scoring_sfn_logs,
  ]
}

# ─── EventBridge Pipes wiring: SQS → SFN (gated) ────────────────────
# Pipes is the AWS-native primitive for SQS → Step Functions delivery.
# Alternatives (Lambda dispatcher, direct API StartExecution) either
# add an extra hop or bypass the queue semantics the DLQ depends on.
#
# Delivery-semantics caveat (READ BEFORE PROMOTING TO CRITICAL PATH):
# Standard workflows only accept FIRE_AND_FORGET starts from Pipes.
# The moment SFN returns 200 to StartExecution, Pipes ACKs SQS and
# the message is gone. Anything that goes wrong AFTER that hand-off
# (region outage, malformed state-machine input, an unhandled error
# path that skips HandleFailure) won't land in the SQS DLQ — SQS
# already considers the message processed. Our DLQ therefore only
# catches failures that happen BEFORE Pipes hands off:
#   - source ARN misconfig
#   - Pipes-role permission drift
#   - StartExecution throttling
# Failures INSIDE the state machine are caught by the Catch blocks
# on each Task state, which route to HandleFailure (a Fail state that
# terminates the execution — visible in the SFN execution history and
# on the CloudWatch failed-execution metric, NOT the SQS DLQ).
#
# Compensating controls at this scale:
#   1. Alarm on StepFunctions ExecutionsFailed > 0 (future work,
#      tracked in ADR-020 Phase 4).
#   2. Beacon-side reconciliation: if a scoring dispatch doesn't see
#      a callback within 5 minutes, requeue.
#
# When to escalate: if the pipeline moves off portfolio scale onto a
# critical path where losing a scoring result is unacceptable, switch
# to the Step Functions callback (task-token) pattern — SFN sends a
# TaskToken on execution start, Pipes waits for a token response, and
# SQS holds the message locked until the entire workflow completes.
# Adds complexity + latency but closes the drop window entirely.

resource "aws_pipes_pipe" "scoring" {
  count = var.scoring_enabled ? 1 : 0

  name     = "${local.scoring_name}-sqs-to-sfn"
  role_arn = aws_iam_role.scoring_pipe.arn
  source   = aws_sqs_queue.scoring_requests.arn
  target   = aws_sfn_state_machine.scoring[0].arn

  source_parameters {
    sqs_queue_parameters {
      # Batch size 1 so each SQS message maps 1:1 to an SFN execution.
      # Batching would complicate the Step Functions input contract
      # and gain little at portfolio volume (~50 scorings/day).
      batch_size = 1
    }
  }

  target_parameters {
    step_function_state_machine_parameters {
      # Standard workflows only support ASYNC (FIRE_AND_FORGET) starts
      # from Pipes; the caller (Pipes) doesn't wait for completion.
      invocation_type = "FIRE_AND_FORGET"
    }
  }

  depends_on = [
    aws_iam_role_policy.scoring_pipe_permissions,
  ]
}

# ─── Outputs ────────────────────────────────────────────────────────

output "scoring_sqs_queue_url" {
  description = "SQS request-queue URL. Beacon API's scoring dispatcher publishes to this URL when SCORING_BACKEND=stepfunctions."
  value       = aws_sqs_queue.scoring_requests.url
}

output "scoring_dlq_url" {
  description = "SQS DLQ URL. Watch depth via CloudWatch; drain manually with `aws sqs receive-message` after inspecting the payload."
  value       = aws_sqs_queue.scoring_dlq.url
}

output "scoring_ecr_repository_url" {
  description = "ECR repo URL for the scoring container image. Push tags here from CI."
  value       = aws_ecr_repository.beacon_scoring.repository_url
}

output "scoring_state_machine_arn" {
  description = "Step Functions state machine ARN. Null until scoring_enabled=true and terraform apply has bootstrapped the pipeline."
  value       = try(aws_sfn_state_machine.scoring[0].arn, null)
}

output "scoring_secret_arns" {
  description = "Secrets Manager ARNs the operator must populate out-of-band before flipping scoring_enabled=true."
  value = {
    anthropic_api_key = aws_secretsmanager_secret.scoring_anthropic_key.arn
    callback_hmac_key = aws_secretsmanager_secret.scoring_callback_hmac.arn
    callback_url      = aws_secretsmanager_secret.scoring_callback_url.arn
    callback_bearer   = aws_secretsmanager_secret.scoring_callback_bearer.arn
  }
}
