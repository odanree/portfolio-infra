# IAM user for Beacon (Hetzner VPS) to publish to the scoring SQS queue
# — ADR-020 phase 2.
#
# The Beacon API needs to enqueue scoring jobs when SCORING_BACKEND is
# `stepfunctions` or `dual`. Since Beacon runs on Hetzner (not EC2), we
# can't use an IAM role attached to compute — the VPS needs a long-lived
# AWS access key.
#
# Blast radius: this user can ONLY sqs:SendMessage on the beacon-scoring
# requests queue. It cannot read the queue, cannot invoke the state
# machine, cannot access other AWS services, cannot list or describe
# anything else in this account. Compromise = attacker can enqueue
# scoring jobs (spend Anthropic credits) but nothing else. Rotation is
# a re-terraform-apply.
#
# Named pattern: narrowly-scoped machine-identity credential at the
# cross-cloud trust boundary. The alternative (STS via API Gateway proxy
# with per-request signing) is defensible at higher scale but is
# overengineered for portfolio traffic. If this key ever leaks in a way
# that makes headlines, revisit.
#
# Bootstrap:
#   1. terraform apply — creates user, policy, access key
#   2. `terraform output -raw scoring_vps_publisher_secret_access_key`
#      to retrieve the secret; the ID is `terraform output
#      scoring_vps_publisher_access_key_id`
#   3. Paste both into Beacon's .env on the VPS:
#        SCORING_AWS_ACCESS_KEY_ID=<id>
#        SCORING_AWS_SECRET_ACCESS_KEY=<secret>
#      (Deliberately prefixed SCORING_ to isolate from any future generic
#      AWS_ACCESS_KEY_ID Beacon might grow.)
#   4. `docker compose up -d api worker` (env changes require recreate,
#      matching the [[project_anthropic_key_attribution]] VPS rotation
#      pattern).

resource "aws_iam_user" "scoring_vps_publisher" {
  name = "${local.scoring_name}-vps-publisher"

  tags = {
    Purpose = "Publishes to the scoring SQS request queue from the Beacon Hetzner VPS. Managed by portfolio-infra terraform."
  }
}

data "aws_iam_policy_document" "scoring_vps_publisher" {
  statement {
    sid       = "SendScoringJobs"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.scoring_requests.arn]
  }
}

resource "aws_iam_user_policy" "scoring_vps_publisher" {
  name   = "${local.scoring_name}-vps-publisher-send"
  user   = aws_iam_user.scoring_vps_publisher.name
  policy = data.aws_iam_policy_document.scoring_vps_publisher.json
}

resource "aws_iam_access_key" "scoring_vps_publisher" {
  user = aws_iam_user.scoring_vps_publisher.name
}

output "scoring_vps_publisher_access_key_id" {
  description = "AWS access key ID for Beacon VPS to publish to the scoring SQS queue. Paste into Beacon's .env as SCORING_AWS_ACCESS_KEY_ID."
  value       = aws_iam_access_key.scoring_vps_publisher.id
}

output "scoring_vps_publisher_secret_access_key" {
  description = "AWS secret access key for the same user. Retrieve with `terraform output -raw scoring_vps_publisher_secret_access_key`. Paste into Beacon's .env as SCORING_AWS_SECRET_ACCESS_KEY."
  value       = aws_iam_access_key.scoring_vps_publisher.secret
  sensitive   = true
}
