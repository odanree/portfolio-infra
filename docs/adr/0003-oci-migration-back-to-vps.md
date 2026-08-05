# ADR-0003: Migrate oc-realestate-intel off AWS EC2 back to the shared Hetzner VPS

- **Status:** Accepted
- **Date:** 2026-08-04
- **Deciders:** Danh Le
- **Supersedes (in part):** [ADR-0002](0002-aws-terraform-marquez-oci.md) — the shared-EC2 host is torn down; the beacon-cdc + beacon-scoring stacks stay on AWS.

## Context

ADR-0002 (2026-06-15) put `oc-realestate-intel` onto a Terraform-managed AWS EC2 (`marquez-oci`, t3.medium + EIP + EBS) alongside Marquez. The deploy worked and was portfolio signal in itself — "I can build production AWS deploys."

By late July 2026, the cost profile had made itself visible:

| Line item | Monthly (Jul '26) |
|---|---:|
| EC2 t3.medium 24/7 | $24.03 |
| EIP / public IPv4 charge | $3.65 |
| EBS 60GB gp3 | $3.71 |
| Secrets Manager ×4 (`marquez-oci/*`) | $2.20 |
| CloudWatch + ECS + others | $3.97 |
| **Total** | **$37.56** |

The Aug forecast in AWS Cost Explorer showed **$51.99 rising** — beacon-scoring Lambdas + Fargate CDC listener now running for real (post-bootstrap), plus normal drift. The marquez-oci EC2 was serving oc-realestate-intel (a low-traffic portfolio demo) at ~8% CPU 24/7.

Meanwhile, the Hetzner VPS already runs the full portfolio compose stack (15+ containers: Beacon, Lumen, ADU, all the shopify demos, wordpress, varnish, solar-*, sec-finint, jd-classifier, portfolio-issues-agent) with headroom. Adding a fourth sibling compose project alongside `beacon`, `lumen`, and `adu-dashboard` was ~0 marginal cost.

Marquez itself had been superseded by Langfuse (already wired in [oc-realestate-intel/app/observability.py](../../../oc-realestate-intel/app/observability.py)), so the "M" in `marquez-oci` was already dead code.

**The question wasn't whether to migrate — it was how to do it without a public outage.**

## Decision

Executed a **strangler-fig cutover** from AWS EC2 to the Hetzner VPS as a sibling compose stack. Portfolio-infra's shared `portfolio-postgres` absorbed the `oci` database; Qdrant + Neo4j moved as dedicated sibling containers. Cloudflare DNS was flipped only after the VPS path was smoke-tested end-to-end through production DNS resolution.

### Patterns applied

- **Strangler-fig cutover.** Both stacks (AWS + VPS) ran in parallel until DNS was ready to flip; rollback was a one-DNS-record revert for 24 hours after cutover. No downtime observed, no traffic served by both stacks simultaneously (single source-of-truth via DNS).
- **Extract-a-bounded-context.** OCI became its own sibling compose project (`oci/` on the VPS, `name: oci` pinned) rather than folding into the portfolio-infra monolith compose. Matches the existing `beacon_jsp-net`, `lumen_lumen-net`, `adu-dashboard_adu-net` pattern — each stack owns its own docker network and lifecycle. Only the shared Postgres (via `portfolio-net` cross-attachment) and portfolio-caddy (via `external-net-4` reverse attachment) cross bounded contexts.
- **Bulkhead pattern.** Neo4j heap explicitly capped at 512MB (`NEO4J_server_memory_heap_max__size: 512m`) so a runaway Cypher query can't OOM the other 15 containers on the shared VPS host. Same principle as an EC2 instance type ceiling, applied at container-runtime granularity.
- **Fail-fast at trust boundary + graceful degradation on runtime path.** The extended `deploy.yml` sibling handler soft-skips (with a clear log line) when a sibling `.env` is missing — it doesn't hard-fail the whole deploy for a new sibling that hasn't finished bootstrapping. But secret material *must* be populated out-of-band by an operator, never pulled from AWS by the deploy runtime. Trust and runtime are separate concerns.
- **Multi-tenant shared Postgres, dedicated stateful stores per tenant.** The `oci` database is one of 8 tenants on the shared `portfolio-postgres` (see [init-db/01-databases.sql](../../init-db/01-databases.sql)). But Qdrant + Neo4j have OCI-specific data with different lifecycle → dedicated containers, dedicated volumes.
- **Idempotent redeploy for external-network dependencies.** The sibling handler runs `docker compose up -d` on the OCI stack **before** the portfolio-infra compose recreates caddy — because caddy's `external-net-4` attachment to `oci_oci-net` requires the network to exist first. Missing that ordering caused a two-deploy failure loop during the first cutover attempt (see "Failure modes" below).

### What ships in this migration

1. **[portfolio-infra#32](https://github.com/odanree/portfolio-infra/pull/32)** — Caddy route for `oci.danhle.net`, `external-net-4` wiring to `oci_oci-net`, `oci` database added to `init-db/01-databases.sql`.
2. **[portfolio-infra#33](https://github.com/odanree/portfolio-infra/pull/33)** — `deploy.yml` extended with `SIBLING_STACK` map so the auto-deploy handles compose projects living outside portfolio-infra's own directory.
3. **[oc-realestate-intel#8](https://github.com/odanree/oc-realestate-intel/pull/8)** — `docker-compose.prod.yml` sibling stack, dual-attached to `oci-net` + `portfolio-infra_portfolio-net`.
4. **[oc-realestate-intel `f20f278`](https://github.com/odanree/oc-realestate-intel/commit/f20f278)** — Hotfix: `name: oci` pinned in the compose file so the network resolves to `oci_oci-net` regardless of checkout dir.
5. **[portfolio-infra#35](https://github.com/odanree/portfolio-infra/pull/35)** — Terraform cleanup removing the marquez-oci EC2 + IAM + Secrets Manager + security group definitions.

## Rationale

### Why migrate now rather than let it ride

- The Aug forecast trending UP ($37 → $52) meant "wait and see" was actively getting more expensive each week.
- OCI is a portfolio demo — no real users depending on AWS-specific behavior. The blast radius of migrating was capped at "I have to fix it if the VPS misbehaves."
- The muscle memory from ADR-0002 (setting up the EC2) was still fresh. Migrating six months later would have meant relearning the AWS side just to tear it down.
- The interview story got **stronger**, not weaker: "designed and deployed to Terraform-managed AWS, ran it in prod, then cost-engineered the migration back to the shared VPS with zero downtime" > "shipped an AWS thing."

### Why the VPS instead of Fargate

Fargate would have preserved the "AWS in the stack" bullet, but the point of the migration was **cost reduction**, and Fargate at OCI's compute shape (~0.5 vCPU always-on with 1GB memory across the stack) prices similarly to a shared t3 slice — not the ~$32/mo → ~$0 the VPS delivers. The VPS was already paid for by other workloads; adding OCI was marginal-cost zero.

### Why not fold OCI into portfolio-infra's main compose

Folding would have kept the total compose file smaller by one project directory, but it would have violated the extract-a-bounded-context pattern already established for beacon, lumen, and adu-dashboard. Bounded contexts matter for blast radius: an OCI Neo4j crash-loop should not require restarting caddy, wordpress, or the Shopify agents. Keeping OCI as a sibling stack means `docker compose -f docker-compose.prod.yml down` on OCI has zero effect on any other workload.

### Why shared Postgres, dedicated Neo4j + Qdrant

Postgres tenants are cheap (schema/database-per-tenant is table-stakes). Neo4j and Qdrant, by contrast, hold OCI-specific data with distinct write patterns (bulk seed, then read-heavy) and separate operational lifecycle (upgrade Qdrant client independently, snapshot Neo4j separately). Sharing them across tenants would have created accidental coupling.

## Consequences

### Positive

- **Cost delta locked in:** AWS bill drops from ~$37/mo → ~$12/mo (residual = beacon-cdc Fargate + beacon-scoring Lambdas + secrets + logs). That's a **~68% cut**, ~$300/yr recovered.
- **Interview artifact:** end-to-end migration executed with three PRs, one hotfix, one destroy PR — traceable in GitHub, clean bounded-context boundaries.
- **Auto-deploy still works.** The extended `deploy.yml` handles OCI just like every other portfolio project — `gh workflow run deploy.yml` from local, no more SSH-and-manual-docker-compose.
- **Bulkhead cap validated:** Neo4j at 512MB heap has served the ~10k parcel dataset without issues in the initial 24h. If the dataset grows, the cap is one env-var change away from being raised.
- **The AWS story is retained** — the terraform module still describes what got built, and ADR-0002 stays as history. The narrative is "I designed the AWS deploy, ran it, then decommissioned it deliberately," not "I never touched AWS."

### Negative

- **Single-VPS failure domain.** OCI now shares physical hardware with beacon, lumen, WordPress, and every other portfolio workload. A Hetzner outage takes everything down together. Historically Hetzner has been reliable, but there's no multi-region story on the VPS side.
- **Cross-context Neo4j operational coupling.** OCI's Neo4j runs on the same host as beacon's Postgres. If Neo4j starts eating memory unexpectedly, beacon's Postgres feels it before OCI does. Bulkhead cap mitigates but doesn't eliminate.
- **Two-repo deploy dependency for OCI.** OCI's runtime behavior depends on both `oc-realestate-intel` (the app) and `portfolio-infra` (the caddy route + shared postgres). A change to the oci_oci-net name breaks caddy silently. Documented in [PR #35](https://github.com/odanree/portfolio-infra/pull/35).
- **Loss of the ECR + Fargate scaling story for OCI.** If OCI ever needed real horizontal scale, the VPS shape doesn't provide it — we'd have to migrate back to AWS or Fly.io or similar. Portfolio scale doesn't need that today.

## Failure modes hit during cutover (and how they were mitigated)

Documenting these because they'll recur when the next sibling stack migrates in.

1. **Deploy #1 failure — `oci_oci-net` didn't exist yet when caddy tried to attach.** The `docker compose up` on portfolio-infra failed because external-net-4 mapped to a network the OCI stack hadn't created yet. Fixed in PR #33 by ordering: sibling handler runs BEFORE the portfolio-infra compose up.

2. **Deploy #2 failure — same root cause, different manifestation.** After PR #33 landed, the sibling handler soft-skipped because oc-realestate-intel's master didn't yet have `docker-compose.prod.yml` (PR #8 merged 9 seconds too late to be seen). Mitigation: the soft-skip logged clearly, and a subsequent `workflow_dispatch` after all three PRs were in fixed it. **Merge order matters** — the runbook now documents it.

3. **Compose project-name mismatch — `oc-realestate-intel_oci-net` instead of `oci_oci-net`.** Docker compose defaults the project name from the working directory (`/opt/oc-realestate-intel`). Fixed by pinning `name: oci` at the top of `docker-compose.prod.yml` (Compose 2.x feature). This is one of those "default assumption is wrong" gotchas that could have been caught in a dry-run test but wasn't. Saved to memory as [`feedback_neo4j_auth_slash_delimiter.md`](../../.claude/projects/.../memory/) sibling for future sibling-stack onboardings.

4. **Neo4j crash-loop — `NEO4J_AUTH` parser broke on `/` in the base64-generated password.** `openssl rand -base64 24` legitimately produced a password containing `/`. Neo4j uses `/` as the user/password delimiter in NEO4J_AUTH, so the parser broke on the first `/`. Fixed by regenerating with `openssl rand -hex 24`. Saved to memory as a permanent rule for any future Neo4j provisioning.

5. **AWS profile confusion — `claude-deploy` profile doesn't exist; the IAM user by that name is under the `default` profile.** Memory had the profile name wrong. Cost one round-trip to diagnose. Memory now updated.

None of these caused a production outage — they all failed *before* the DNS flip and were surfaced by the deploy workflow's `set -euo pipefail`. But each cost 5-15 min to diagnose and would have been avoidable with a compose-project-name test in CI.

## Alternatives considered

- **Scheduled stop/start** of the AWS EC2 (only running 4h/day for interviews/demos) — cuts EC2 cost ~80% to ~$8/mo total. Rejected because EBS + EIP still charge when stopped, and it doesn't remove the AWS operational overhead. Cost-ineffective compared to full migration.
- **Compute Savings Plan** (1yr, no upfront) — ~30% off EC2, ~$7/mo savings. Locks in a year of AWS commitment. Rejected because the migration was clearly better ROI.
- **Migrate to Fargate on AWS** — preserves "AWS in the stack" bullet but prices similarly to the current EC2. Rejected because cost delta was the primary driver.
- **Migrate to Fly.io or Railway** — hosted PaaS with pay-per-use compute. Would have added a third infrastructure vendor to the portfolio (already had AWS + Hetzner + Cloudflare + Vercel). Rejected on YAGNI grounds.
- **Do nothing, absorb the cost** — $37/mo × 12 = $444/yr. The migration took a half-day. ROI was ~1 year even if you value the time at market rates.

## Rules going forward

1. **Any new demo/portfolio workload starts on the VPS as a sibling compose stack.** AWS/Fargate/Lambda are reserved for workloads that genuinely need them (beacon-scoring needs the Anthropic-Lambda cost model; beacon-cdc needs always-on task management).
2. **Every sibling stack gets `name: <project>` pinned in its compose file.** Never rely on the default project-name inference from checkout directory — it's dependent on the operator's filesystem layout.
3. **Neo4j passwords generated with `openssl rand -hex 24`** (or another slash-safe method), NEVER `openssl rand -base64`. Memory saved as a permanent rule.
4. **`.env` for a new sibling stack is populated out-of-band by the operator** before the first deploy triggers. The deploy workflow's soft-skip is a safety net, not a workflow.
5. **When onboarding the next sibling stack, add it to the `SIBLING_STACK` map in `deploy.yml`** and the pre-merge runbook — don't reintroduce the manual SSH pattern.

## Follow-ups

- **`terraform destroy` + merge [PR #35](https://github.com/odanree/portfolio-infra/pull/35)** — the destroy hasn't happened yet; the ADR ships the day after the DNS flip, with the destroy PR ready for tomorrow.
- **Cloudflare SSL mode verification** — confirm origin traffic uses **Full** or **Full (Strict)** (not Flexible). Cloudflare → Caddy currently works either way, but Flexible leaks plaintext inside Hetzner.
- **Qdrant client/server version alignment** — client 1.18 vs server 1.11 mismatch warning during oci-app startup. Wire-compatible today, one version bump away from breaking. Pin the server image or downgrade the pip package.
- **Extract the `SIBLING_STACK` pattern into a generic helper** — right now it's inline in `deploy.yml`. When there are 3+ sibling stacks, it deserves its own script.
- **Consider migrating `var.tag_name` prefix from `marquez-oci` → `portfolio` in a separate PR** — historical prefix. Cosmetic, but the current name misleads about what the AWS residual stack contains. Cost: recreates every beacon-cdc + beacon-scoring resource.

## Links

- [PR #32](https://github.com/odanree/portfolio-infra/pull/32) — caddy + shared postgres wiring
- [PR #33](https://github.com/odanree/portfolio-infra/pull/33) — deploy.yml sibling-stack auto-deploy
- [PR #35](https://github.com/odanree/portfolio-infra/pull/35) — terraform destroy marquez-oci
- [oc-realestate-intel PR #8](https://github.com/odanree/oc-realestate-intel/pull/8) — VPS sibling compose stack
- [oc-realestate-intel `f20f278`](https://github.com/odanree/oc-realestate-intel/commit/f20f278) — `name: oci` hotfix
- [ADR-0001](0001-routing-architecture.md) — two-VPS routing architecture (the pattern this migration slotted into)
- [ADR-0002](0002-aws-terraform-marquez-oci.md) — the original AWS deploy this supersedes (in part)
