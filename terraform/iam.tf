# Instance profile that lets the EC2 read Secrets Manager values for
# Anthropic + Langfuse + any DB passwords. No write access — secrets are
# managed by the operator via `aws secretsmanager put-secret-value`.

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.tag_name}-instance-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "secrets_read" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.tag_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "secrets_read" {
  name   = "${var.tag_name}-secrets-read"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.secrets_read.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.tag_name}-instance-profile"
  role = aws_iam_role.instance.name
}

data "aws_caller_identity" "current" {}
