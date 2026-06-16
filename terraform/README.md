# `marquez-oci` — Terraform module

Single-EC2 host on AWS that runs **two demo apps**:

- [Marquez](https://github.com/MarquezProject/marquez) — OpenLineage backend for Beacon's data-lineage events. Live at `lineage.danhle.net`.
- [oc-realestate-intel](https://github.com/odanree/oc-realestate-intel) — LangGraph multi-agent over Orange County parcel data. Live at `oci.danhle.net`.

Both apps stay independent (separate compose projects, separate volumes); they share the host's CPU, memory, and a single Caddy that fronts TLS for both subdomains.

## Architecture

```
                      Cloudflare (DNS-only or proxied)
                            │
              ┌─────────────┼─────────────┐
              ▼                           ▼
       lineage.danhle.net           oci.danhle.net
              │                           │
              └─────────────┬─────────────┘
                            ▼
                  ┌─────────────────────┐
                  │     EC2 t3.medium   │  Elastic IP
                  │     Ubuntu 24.04    │  ($30/mo + EBS)
                  │                     │
                  │   ┌──────────────┐  │
                  │   │ Caddy        │  │  Auto-issued Let's
                  │   │ (TLS, route) │  │  Encrypt certs
                  │   └──┬───────┬───┘  │
                  │      │       │      │
                  │  ┌───▼──┐ ┌──▼───┐  │
                  │  │marquez│ │ oci  │  │  Independent
                  │  │ stack │ │stack │  │  compose projects
                  │  └───┬──┘ └──┬───┘  │
                  │      │       │      │
                  │   shared docker network
                  └──────┼───────┼──────┘
                         │       │
                  Secrets Manager (Anthropic, Langfuse)
                  via EC2 IAM role — no keys in image / repo
```

## What this module creates

| Resource | Purpose | Cost |
|---|---|---|
| EC2 t3.medium | The host | ~$30/mo |
| EBS gp3 60 GiB | Root volume, holds OS + docker images + named-volume data | ~$5/mo |
| Elastic IP | Stable public IP for DNS | $0 while attached |
| Security group | SSH from operator IP, 80/443 from world | $0 |
| IAM role + instance profile | Lets the EC2 fetch Secrets Manager values | $0 |
| Secrets Manager (2 secrets) | Anthropic API key + Langfuse keys (values populated out-of-band) | ~$0.80/mo |
| **Total** | | **~$35–37/mo** |

State backend: `s3://tf-state-portfolio-478818964123/marquez-oci/terraform.tfstate` with DynamoDB lock table `tf-state-lock` (both in us-east-1).

## Layout

```
terraform/
├── versions.tf          required_providers + S3 backend + default tags
├── variables.tf         tunables (region, instance_type, key_pair, SSH CIDR, …)
├── network.tf           default VPC lookup + security group
├── iam.tf               instance profile + Secrets Manager read policy
├── secrets.tf           Secrets Manager entries (values set out-of-band)
├── compute.tf           AMI lookup + EC2 + EBS + Elastic IP + user_data
├── outputs.tf           IP, SSH command, secret ARNs
└── README.md            this file
```

## Usage

### One-time bootstrap (state backend)

Already done — the S3 bucket + DynamoDB table exist. If you ever recreate from scratch:

```bash
# in us-east-1
aws s3api create-bucket --bucket tf-state-portfolio-<ACCOUNT_ID>
aws s3api put-bucket-versioning --bucket tf-state-portfolio-<ACCOUNT_ID> \
    --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket tf-state-portfolio-<ACCOUNT_ID> \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket tf-state-portfolio-<ACCOUNT_ID> \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name tf-state-lock \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
```

### Apply

```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

### Populate secrets

```bash
aws secretsmanager put-secret-value \
    --secret-id marquez-oci/anthropic-api-key \
    --secret-string "sk-ant-..."

aws secretsmanager put-secret-value \
    --secret-id marquez-oci/langfuse \
    --secret-string '{"public_key":"pk-lf-...","secret_key":"sk-lf-...","host":"https://us.cloud.langfuse.com"}'
```

### Deploy the app stack

The Terraform brings the host up with docker + compose + awscli installed and the IAM role attached. Application deployment (compose files, Caddyfile, secret rendering) is a separate step — see `../scripts/deploy-app.sh` (work in progress).

### DNS

After `terraform apply` finishes, point Cloudflare DNS at the output `public_ip`:

- `lineage.danhle.net` A → `<public_ip>` (DNS-only at first; flip to proxied once Caddy has cert)
- `oci.danhle.net` A → `<public_ip>` (same)

## Design notes

- **Why default VPC, not a dedicated one**: portfolio scale doesn't need network isolation between environments. A real prod deploy would create a VPC per env.
- **Why Secrets Manager, not SSM Parameter Store**: SecretsManager auto-rotates and integrates cleanly with the EC2 IAM role pattern. SSM is cheaper but lacks the rotation story.
- **Why secret values not in Terraform**: anything in `terraform.tfstate` is visible to anyone with state-bucket read. Setting values out-of-band via the CLI keeps secret material out of state entirely.
- **Why no `recovery_window_in_days` on secrets**: when `terraform destroy` runs, we want secrets gone immediately rather than a 7-day soft-delete period — they're cheap to recreate and we don't want the same name "in use" if we re-apply.
- **Why `lifecycle.ignore_changes = [ami]`**: Canonical publishes new Ubuntu AMIs frequently. Without this, `terraform plan` would propose replacing the instance every week. AMI updates should be deliberate, not drift-driven.

## Future work

- Move Postgres for oc-realestate-intel to RDS (managed DB story, +$15/mo).
- Move stateful data (Postgres, Qdrant, Neo4j, Marquez DB) to separate EBS volumes so we can replace the instance without losing data.
- ECR for app images so `terraform apply` deploys a specific version rather than relying on `git pull` on the box.
- Switch to dedicated VPC + private/public subnets once anything sensitive lives here.
