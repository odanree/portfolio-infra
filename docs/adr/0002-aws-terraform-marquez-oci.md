# ADR-0002: Terraform-managed AWS host for Marquez (and, soon, oc-realestate-intel)

- **Status:** Accepted
- **Date:** 2026-06-15
- **Deciders:** Danh Le

## Context

A standalone Marquez backend was deployed to AWS EC2 earlier on 2026-06-15 (see `lineage.danhle.net` write-ups) to solve the ARM-incompatibility problem for Beacon's data lineage backend. It worked, but the deploy was done by hand via the AWS console and a sequence of CLI calls — no IaC, no version-controlled story for "how does this host exist," no clear path to add the next workload.

This ADR captures the migration to a Terraform-managed host and the design decisions behind the module that lives in `terraform/`.

The trigger for codifying it now: the same EC2 will host **oc-realestate-intel** (Gap #1 from the original Deloitte JD gap analysis) in the next deploy round. Standing up a second hand-rolled host would either duplicate the manual setup or, worse, drift from the first. Owning both deploys in Terraform from the start is cheaper than retrofitting later.

## Decision

A new Terraform module at `terraform/` provisions and manages a **single EC2 t3.medium** in `us-east-1` that hosts multiple demo apps as **independent docker-compose projects** sharing a docker network called `web`. State lives in S3 with DynamoDB locking.

### What ships in this round

- **Marquez** — migrated tonight from the standalone EC2 to the Terraform-managed one. Same compose, same images, same data shape; the standalone instance is decommissioned.

### What lands next round

- **oc-realestate-intel** — deployed onto the same EC2 as a second compose project joining the `web` network. Caddy will gain an `oci.danhle.net` route block (currently commented out in `terraform/app/Caddyfile`).

### State backend

```
s3://tf-state-portfolio-478818964123/marquez-oci/terraform.tfstate
DynamoDB:  tf-state-lock (PAY_PER_REQUEST)
Region:    us-east-1
```

Bucket is versioned, AES-256 encrypted at rest, public access blocked. DynamoDB table is pay-per-request (cost is effectively $0 at this scale).

### Resources Terraform owns

| Resource | Purpose | Notes |
|---|---|---|
| `aws_security_group` `marquez-oci-sg` | SSH (operator IP), HTTP, HTTPS | All outbound permitted (Anthropic API, Langfuse, apt, etc) |
| `aws_iam_role` + instance profile | Box can read Secrets Manager values | `iam:PassRole` for the EC2 to assume the role |
| `aws_iam_role_policy` | Grants `secretsmanager:GetSecretValue` scoped to `marquez-oci/*` | No other AWS API access — small blast radius if key leaks |
| `aws_secretsmanager_secret` × 2 | Anthropic API key + Langfuse JSON | **Values populated out-of-band**, never via Terraform |
| `aws_instance` | t3.medium, Ubuntu 24.04, 60 GB gp3 root volume | `user_data` installs docker/compose/jq/aws-cli at boot |
| `aws_eip` | Stable public IP for DNS | $0 while attached; ~$3.6/mo if detached |

Outputs: `instance_id`, `public_ip`, `ssh_command`, `secrets_arns`, `instance_profile`.

### What Terraform deliberately doesn't own

- **App images & compose files** — app deploy is a separate step (`scp` + `ssh` for now; will become a script). Keeps the `terraform/` files free of churn whenever an app config changes.
- **Secret material** — `terraform.tfstate` should never contain credentials. Operator populates secret values via `aws secretsmanager put-secret-value` after `terraform apply`.
- **DNS records** — Cloudflare DNS isn't managed by AWS Terraform. Cloudflare MCP / API token / manual UI does this. Cross-cloud DNS-in-Terraform was considered and rejected for v1 — too much coupling between providers for a portfolio-scale deploy.
- **Postgres on RDS** — not in v1. Apps that need Postgres run it in their own compose with named volumes. Moving to RDS is a follow-up when JD signal or backup requirements demand it.

### Why a single shared host rather than one host per app

- **Cost**. Two t3.smalls would be ~$30/mo combined; a single t3.medium with 4 GB RAM hosts both with room to spare for ~$30/mo total.
- **Operational simplicity**. One AMI to keep current, one set of OS patches, one set of security-group rules, one ssh key pair.
- **Honest scaling story**. The next time something on this box needs more than its share — e.g., oc-realestate-intel's LangGraph workers under load — the right answer is to split, not over-provision. Split is a 30-minute Terraform copy job.

### Why default VPC, not a dedicated one

Real prod separates dev/staging/prod into their own VPCs. Portfolio doesn't have that complexity. Importing the default VPC keeps the module short. When/if this graduates beyond portfolio, the migration is `aws_vpc` + `aws_subnet` + `aws_route_table` + cutover, ~1 hour.

### Why Secrets Manager and not SSM Parameter Store

Both work. Secrets Manager has built-in rotation hooks, cleaner IAM integration with rotation, and a separate cost surface that won't get accidentally polluted with parameters. ~$0.40/secret/month is acceptable. Parameter Store would have been free but doesn't pay back the slight complexity savings.

### Why secret values out-of-band, not Terraform-managed

The point of state encryption is making the encrypted state file safe to share among engineers. The point of NOT putting raw secrets in state is making sure those secrets aren't visible to anyone with state-bucket read. These complement each other. Terraform's `aws_secretsmanager_secret_version` resource exists, but using it pulls secret material through `terraform.tfstate` — undoing the second guarantee. Out-of-band `put-secret-value` keeps secrets out of state entirely.

### Why `lifecycle.ignore_changes = [ami, user_data]`

Canonical publishes new Ubuntu 24.04 AMIs almost every week. Without `ignore_changes = [ami]`, every `terraform plan` would propose **replacing the instance** to pick up the latest AMI. That's destructive drift. AMI upgrades should be a deliberate manual operation (`terraform taint` + `apply`), not a default plan side-effect.

`user_data` is similar: edits to the bootstrap script should not implicitly replace a running production instance.

### Cost shape

| Line item | Monthly |
|---|---|
| EC2 t3.medium | ~$30 |
| EBS gp3 60 GiB | ~$5 |
| Elastic IP (attached) | $0 |
| Secrets Manager (2 secrets) | ~$0.80 |
| DynamoDB state lock | ~$0 (PAY_PER_REQUEST at this scale) |
| S3 state bucket | ~$0 (under 1 KB) |
| **Total** | **~$36** |

The pre-Terraform standalone Marquez EC2 + EIP was ~$17/mo. Moving Marquez to this t3.medium and bringing oc-realestate-intel along next round costs roughly **$36 total for both apps**, not $34 + $30 if they each ran on their own hosts.

## Consequences

**Positive**
- Real IaC story to show. `terraform apply` reproduces the infra deterministically; the README walks through bootstrap, secrets population, and DNS.
- Cost is bounded — the shared-host pattern + `ignore_changes` keeps the AWS bill predictable.
- Adding the next workload is mechanical: extend `terraform/app/docker-compose.yml`, add a Caddy block, scp, restart.
- Secret hygiene is good: state never sees credentials; the IAM policy is scoped to `marquez-oci/*` so a leaked instance role gets at most these two secrets.

**Negative**
- Two-step deploy (Terraform → manual scp/ssh) is leaky. The first time something needs to deploy on a schedule (CI), this becomes a real pain point.
- A single host means a single failure domain. If the box goes down, both `lineage.danhle.net` and (eventually) `oci.danhle.net` go down together.
- No CI: changes to `terraform/` need a human running `terraform apply` from their machine. GitHub Actions OIDC + Terraform-action would lift this; out of scope for v1.

## Alternatives considered

- **ECS Fargate per app** — proper containerized orchestration on AWS. Right answer at scale; multi-weekend Terraform to land cleanly. v1 is single-EC2 for cost + simplicity.
- **Lightsail Containers** — cheaper $7/mo entry tier. Looked at it; the constraints (no IAM role attachments, limited compose features) make it a poor fit when the goal is to demonstrate "I can build production AWS deploys."
- **Heroku / Render / Railway** — would work but doesn't deliver "AWS in active stack" JD signal.
- **Two separate Terraform-managed hosts (one per app)** — clean isolation, ~$60/mo (two t3.smalls). Rejected because the workloads are small and the failure-domain argument is weaker than the cost argument at this scale.
- **Use the existing standalone EC2 + import to Terraform** — considered. The compose layout and IAM didn't match what we wanted long-term; faster to redeploy onto a fresh Terraform-managed instance and decommission the standalone.

## Rules going forward

1. **All AWS infrastructure changes go through Terraform.** No more console clicks for "just this one thing" — the state file becomes the source of truth, divergence eats hours later.
2. **Secrets stay out of state.** Never `aws_secretsmanager_secret_version` with the value inline; always `put-secret-value` out-of-band.
3. **`terraform plan` should always be no-op on a clean repo.** If `plan` proposes changes after a fresh checkout, the state is drifting and we fix it before anything else.
4. **Cost-impactful changes (instance type, EBS size, new managed services) need an ADR amendment** so the cost trajectory is captured deliberately.
5. **`terraform destroy` is allowed only after manual confirmation that nothing else depends on the host.** The current `recovery_window_in_days = 0` on secrets means destroy is fast and irreversible — be deliberate.

## Follow-ups

- Add `oc-realestate-intel` to the compose + Caddyfile + DNS (Gap #1 continuation).
- GitHub Actions OIDC → AWS for `terraform plan` on PR and `apply` on merge to `master` (gated by a manual approval environment).
- Move stateful data (Postgres for oci, Marquez DB, Qdrant, Neo4j) to dedicated EBS volumes so the EC2 can be replaced without data loss.
- Once anything on this box becomes load-bearing (real users, not portfolio), revisit RDS for Postgres.
- Consider a small Bastion or SSM Session Manager rather than `22/0.0.0.0/0` for SSH.

## Links

- Terraform module: [`../../terraform/`](../../terraform/)
- App stack: [`../../terraform/app/`](../../terraform/app/)
- Standalone Marquez deploy history (pre-Terraform): [`docs/adr/0001-routing-architecture.md`](0001-routing-architecture.md)
- Beacon's data-lineage worker (the upstream that emits to this host): https://github.com/odanree/job-search-pipeline
