# portfolio-infra AWS Terraform

Manages the residual AWS footprint for the portfolio after **most workloads moved to the Hetzner VPS**. Post-migration, this module provisions three things:

1. **beacon-scoring** — Lambda + Step Functions + SQS + EventBridge Pipes for the two-tier Haiku/Sonnet job-scoring pipeline (ADR-020).
2. **beacon-cdc-listener** — Always-on Fargate task that LISTENs to the Beacon Postgres CDC and posts change events to a Vercel deploy hook (ADR-021 phase 3b).
3. **GitHub Actions OIDC** — Role that lets `job-search-pipeline` CI push scoring images to ECR without long-lived AWS keys.

State backend: `s3://tf-state-portfolio-478818964123/marquez-oci/terraform.tfstate` with DynamoDB lock table `tf-state-lock` (both in `us-east-1`). The state-key path still says `marquez-oci/` for historical reasons — renaming the key would migrate state and isn't worth the risk for a cosmetic issue.

## What used to live here

Until August 2026, this module also managed a **`marquez-oci` EC2** (t3.medium + EIP + EBS ≈ $32/mo) that hosted [oc-realestate-intel](https://github.com/odanree/oc-realestate-intel) at `oci.danhle.net`. OCI was moved to the shared Hetzner VPS as a sibling compose stack ([portfolio-infra#32](https://github.com/odanree/portfolio-infra/pull/32), [portfolio-infra#33](https://github.com/odanree/portfolio-infra/pull/33), [oc-realestate-intel#8](https://github.com/odanree/oc-realestate-intel/pull/8)) and the EC2 + its supporting IAM/SG/Secrets Manager resources were destroyed. This PR is the terraform cleanup that removes the now-orphaned definitions from state.

## Layout

```
terraform/
├── versions.tf                    required_providers + S3 backend + default tags
├── variables.tf                   tunables (tag_name still used as prefix by beacon-*)
├── network.tf                     default VPC + subnet data sources (shared with beacon-cdc)
├── outputs.tf                     beacon-cdc + gh-actions outputs
├── beacon-cdc.tf                  Fargate CDC listener stack
├── beacon-scoring.tf              Haiku/Sonnet Lambda + SFN + Pipes + secrets
├── beacon-scoring-vps-publisher.tf VPS SNS publisher gateway
├── gh-actions-oidc.tf             OIDC role for job-search-pipeline CI
└── README.md                      this file
```

## Usage

```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

## Design notes

- **Why `var.tag_name = "marquez-oci"` is still there**: it's baked into every resource name across beacon-cdc + beacon-scoring (`${var.tag_name}-cdc-listener`, `${var.tag_name}/beacon-scoring/...`, etc.). Renaming would recreate all of them, so the name lives on as a historical prefix.
- **Why default VPC + subnets**: portfolio scale doesn't need network isolation between environments. A real prod deploy would create a VPC per env.
- **Why Secrets Manager, not SSM Parameter Store**: SecretsManager integrates cleanly with Lambda / Fargate task-role secret-fetching. SSM is cheaper but SecretsManager's rotation + auto-mount story is what beacon-scoring needs.
- **Why secret values not in Terraform**: anything in `terraform.tfstate` is visible to anyone with state-bucket read. Setting values out-of-band via `aws secretsmanager put-secret-value` keeps secret material out of state entirely.
- **Why no `recovery_window_in_days` on secrets**: on `terraform destroy`, we want secrets gone immediately rather than a 7-day soft-delete period — they're cheap to recreate and we don't want the same name "in use" if we re-apply.

## Cost profile (post-migration)

| Resource | Monthly |
|---|---:|
| Fargate CDC listener (1 × 0.25 vCPU / 0.5 GB always-on) | ~$6 |
| Lambda + Step Functions + Pipes (Haiku + Sonnet scoring, ~50 jobs/day) | ~$2 |
| Secrets Manager (~5 secrets across beacon-cdc + beacon-scoring) | ~$2 |
| CloudWatch Logs (Fargate + Lambda) | ~$1 |
| Route 53 | $0.50 |
| **Total** | **~$12/mo** |

(Down from ~$37/mo pre-migration. The delta was the marquez-oci EC2 + its EIP + EBS + supporting secrets.)
