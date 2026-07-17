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

# ─── job-search-pipeline CI role: push beacon-scoring image + update
# Lambda function code on the 3 scoring lambdas (ADR-020 phase 6 —
# closes the manual deploy loop that bit us during phase 5).
#
# Sibling to gh-actions-beacon-mcp: same OIDC issuer, different repo
# trust, different resource scope. This role's blast radius is:
#   - Push to the marquez-oci/beacon-scoring ECR repo (nothing else)
#   - UpdateFunctionCode on the 3 marquez-oci-beacon-scoring-*
#     Lambda functions (nothing else)
#   - Cannot invoke, cannot read, cannot modify config, cannot touch
#     any other AWS resource
#
# The paired ecr:GetAuthorizationToken permission is on Resource: *
# because AWS requires it (no per-resource ARN for that action) —
# same shape as the beacon-mcp role above.

data "aws_iam_policy_document" "gh_actions_job_search_pipeline_assume" {
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
    # Scoped narrowly — only the job-search-pipeline master branch
    # (and tags) can assume this role. PR builds run under
    # refs/pull/*/merge and are NOT allowed to push.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:odanree/job-search-pipeline:ref:refs/heads/master",
        "repo:odanree/job-search-pipeline:ref:refs/tags/*",
      ]
    }
  }
}

resource "aws_iam_role" "gh_actions_job_search_pipeline" {
  name               = "gh-actions-job-search-pipeline"
  assume_role_policy = data.aws_iam_policy_document.gh_actions_job_search_pipeline_assume.json
  description        = "Assumed by job-search-pipeline GitHub Actions on master + tags. Scoped to ECR push on the beacon-scoring repo + Lambda UpdateFunctionCode on the 3 scoring lambdas only."
}

data "aws_iam_policy_document" "gh_actions_job_search_pipeline_ecr_push" {
  # Login for docker to talk to ECR at all — see note above.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Read + push scoped to the beacon-scoring repo only.
  statement {
    sid = "EcrPushBeaconScoring"
    actions = [
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.beacon_scoring.arn]
  }

  # Update Lambda code on the 3 scoring functions after the image push
  # settles. Wildcard-suffix pattern matches the existing scoring SFN
  # role's shape — bounds blast radius to the beacon-scoring namespace.
  statement {
    sid       = "UpdateScoringLambdas"
    actions   = ["lambda:UpdateFunctionCode"]
    resources = ["arn:aws:lambda:${var.region}:*:function:${local.scoring_name}-*"]
  }

  # Read Lambda config to verify updates landed (harmless, useful for
  # workflow post-conditions like "wait until CodeSha256 matches the
  # pushed digest").
  statement {
    sid       = "ReadScoringLambdas"
    actions   = ["lambda:GetFunction", "lambda:GetFunctionConfiguration"]
    resources = ["arn:aws:lambda:${var.region}:*:function:${local.scoring_name}-*"]
  }
}

resource "aws_iam_role_policy" "gh_actions_job_search_pipeline_ecr_push" {
  name   = "gh-actions-job-search-pipeline-ecr-push"
  role   = aws_iam_role.gh_actions_job_search_pipeline.id
  policy = data.aws_iam_policy_document.gh_actions_job_search_pipeline_ecr_push.json
}

output "gh_actions_job_search_pipeline_role_arn" {
  description = "OIDC role ARN for the job-search-pipeline build-scoring-lambda.yml workflow. Paste into the JSP repo's GitHub → Settings → Variables (repository) → SCORING_LAMBDA_CI_ROLE_ARN. Once set + the workflow flips to push:master trigger, image rebuilds run automatically on merge."
  value       = aws_iam_role.gh_actions_job_search_pipeline.arn
}
