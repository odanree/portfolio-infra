# GitHub Actions → AWS via OIDC.
#
# ADR-021 phase 3c needs a way for beacon-mcp's GitHub Actions workflow
# to push container images to ECR without long-lived AWS credentials
# stored in GitHub Secrets. OIDC is the modern answer: GitHub Actions
# presents a signed JWT proving the workflow context (repo + branch),
# and AWS's STS exchanges it for temporary credentials scoped to a
# specific IAM role.
#
# Two pieces here:
#
#   1. aws_iam_openid_connect_provider — one per account, trusts the
#      GitHub OIDC issuer. Reusable by any future workflow (portfolio,
#      job-search-pipeline, etc.).
#
#   2. aws_iam_role.gh_actions_beacon_mcp — scoped to the beacon-mcp
#      repo, master branch only. Attached policy grants ECR push on
#      the beacon-cdc-listener repo and nothing else.
#
# To add a new repo or workflow later, create another aws_iam_role
# with a matching trust policy — the OIDC provider is shared.

# ─── OIDC provider (shared across all GH Actions integrations) ──────

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# ─── beacon-mcp CI role: push listener image to ECR ─────────────────

data "aws_iam_policy_document" "gh_actions_beacon_mcp_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Scoped narrowly — only the beacon-mcp master branch (and tags)
    # can assume this role. PR builds run under refs/pull/*/merge
    # and are NOT allowed to push (they can still build for
    # verification via `docker build` inside the runner).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:odanree/beacon-mcp:ref:refs/heads/master",
        "repo:odanree/beacon-mcp:ref:refs/tags/*",
      ]
    }
  }
}

resource "aws_iam_role" "gh_actions_beacon_mcp" {
  name               = "gh-actions-beacon-mcp"
  assume_role_policy = data.aws_iam_policy_document.gh_actions_beacon_mcp_assume.json
  description        = "Assumed by beacon-mcp GitHub Actions on master + tags. Scoped to ECR push on the beacon-cdc-listener repo only."
}

data "aws_iam_policy_document" "gh_actions_beacon_mcp_ecr_push" {
  # Login for docker to talk to ECR at all
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # required by API — no per-resource scoping possible for this action
  }

  # Read + push scoped to the beacon-cdc-listener repo
  statement {
    sid = "EcrPushBeaconCdcListener"
    actions = [
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.beacon_cdc_listener.arn]
  }
}

resource "aws_iam_role_policy" "gh_actions_beacon_mcp_ecr_push" {
  name   = "gh-actions-beacon-mcp-ecr-push"
  role   = aws_iam_role.gh_actions_beacon_mcp.id
  policy = data.aws_iam_policy_document.gh_actions_beacon_mcp_ecr_push.json
}
