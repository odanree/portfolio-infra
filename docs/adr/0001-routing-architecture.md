# ADR-0001: Two-VPS architecture with portfolio-caddy as the single ingress

- **Status:** Accepted
- **Date:** 2026-06-15
- **Deciders:** Danh Le

## Context

Six months in, the portfolio runs across **two Hetzner VPSes** and a single Cloudflare zone (`danhle.net`). Without this document captured, it's easy for a future self (or a reviewer) to look at `portfolio-infra/caddy/Caddyfile` and conclude *"all apps live on the portfolio-infra VPS"* — they don't. Beacon and Lumen run on their own host. The reason traffic still works correctly is non-obvious until you know about the overlay network.

## Current state

```
                          Cloudflare DNS + proxy
                                   │
                                   ▼
                       ┌─────────────────────────┐
                       │  portfolio-caddy        │
                       │  (the only public TLS   │
                       │  termination point)     │
                       │  Hetzner VPS A          │
                       │  65.108.243.192         │
                       └─────────────┬───────────┘
                                     │
                  ┌──────────────────┼──────────────────┐
                  │ docker network   │  overlay network │
                  ▼                  ▼                  ▼
        ┌─────────────────┐  ┌──────────────┐  ┌──────────────────┐
        │ Apps on VPS A   │  │ (same host)  │  │ Apps on VPS B    │
        │ — oci-*         │  │              │  │ — beacon-*       │
        │ — shopify-*     │  │              │  │ — beacon-marquez │
        │ — compensation-*│  │              │  │ — lumen-*        │
        │ — sec-finint    │  │              │  │ — adu-*          │
        │ — portfolio-*   │  │              │  │                  │
        │ — jd-classifier │  │              │  │                  │
        │ — parking-det.  │  │              │  │                  │
        │ — wordpress     │  │              │  │                  │
        └─────────────────┘  └──────────────┘  └──────────────────┘
```

The overlay lets portfolio-caddy reach containers on either host as if they were local — `reverse_proxy beacon-frontend:3000` resolves across the overlay to a container on VPS B. That's why this Caddyfile has blocks for services whose containers don't appear in VPS A's `docker ps`.

## Decision

Two layers, separately scoped:

### Layer 1 — Routing & TLS (centralized in `portfolio-infra`)

- **One Caddy** (`portfolio-caddy` on VPS A) handles TLS + reverse-proxy for every `*.danhle.net` subdomain.
- **All subdomain routes** live in `portfolio-infra/caddy/Caddyfile` regardless of which VPS hosts the target container. Adding a new route is a portfolio-infra PR.
- **TLS certs** auto-managed via Let's Encrypt + Cloudflare DNS-01 challenges.
- **Cloudflare Access** is the auth layer for protected subdomains (e.g. `lineage.danhle.net`, internal dashboards). Caddy serves an open backend; CF Access in front gates browser access. This avoids managing basic-auth hashes in the Caddyfile.

### Layer 2 — App services (per-app compose stacks)

- Each app owns its **own `docker-compose.yml`** in its own repo (Beacon: `job-search-pipeline`; Lumen: `lumen`; etc).
- Apps deploy to whichever VPS makes sense for them — typically VPS B for the heavy multi-service apps (Beacon's 12+ services, Lumen's 5+).
- Apps **never** edit portfolio-infra's Caddyfile inside their own compose. They expose a container, and the Caddyfile here proxies to it.

### Why two layers, not one mega-compose

If everything moved into portfolio-infra's compose, it'd be a 50+ service file with conflicting envs, no app-level isolation, and PRs from every app would land in one repo. The current split keeps each app reviewable in isolation while centralizing the only thing that genuinely benefits from being central: the public ingress.

### Why two VPSes, not one bigger box

Beacon's stack alone is ~12 services + a 16 GB Postgres. Combining it with portfolio-infra's 22 services on one host would push memory above what a single Hetzner CX31 can comfortably hold, and any spike in one app would degrade everything. Two right-sized boxes cost about the same as one big box but isolate failure domains.

## Consequences

**Positive**
- One file to grep when answering *"where does `foo.danhle.net` go?"* — this Caddyfile.
- Per-app composes stay reviewable, deployable, and rollback-able independently.
- App teams (future-you with hat A vs hat B) don't have to coordinate compose changes across repos.
- Adding a route for a new service is one PR + one `caddy_reload`.

**Negative**
- The Caddyfile contains hostnames for containers that **aren't visible in VPS A's `docker ps`** — confusing without this ADR. Every "ghost route" needs a comment pointing at this doc.
- Two VPSes = two hosts to patch, two SSH access policies, two backups. The infra-mcp tool covers VPS A; Beacon's VPS is managed separately.
- The overlay network is a single point of failure for cross-host routing. If it breaks, `beacon.danhle.net` 502s even though Beacon itself is up.

## Alternatives considered

- **Move all apps into portfolio-infra's compose** — rejected. See "Why two layers" above.
- **Run a Caddy on each VPS, point Cloudflare DNS to whichever** — rejected. Two Caddies = two TLS-cert lifecycles, two reload procedures, no single source of truth for routes.
- **Use a managed proxy (Cloudflare Tunnel, Ngrok, Tailscale Funnel)** — viable for new apps, but reworking the existing routes to one of these is high-effort low-reward.
- **Consolidate to one bigger Hetzner box** — possible but increases blast radius and re-introduces the noisy-neighbor problem. Two right-sized boxes is the better trade.

## Rules going forward

1. **New route → portfolio-infra PR.** Even if the target container lives on VPS B, the Caddy block lives here.
2. **Comment every cross-host route.** If the target container isn't on VPS A, add a one-line comment naming the host it's on, so the next reader doesn't go grepping for a container that "doesn't exist."
3. **Auth via Cloudflare Access**, not Caddy basicauth. Caddy serves an open backend; CF Access policy gates browser traffic.
4. **App composes stay in app repos.** Don't smuggle app services into portfolio-infra/docker-compose.yml; it's reserved for infra-level services (portfolio-caddy, portfolio-postgres, portfolio-redis, the WordPress CMS, monitoring).
5. **Caddy reload** is via the `caddy_reload_tool` MCP or `docker exec portfolio-caddy caddy reload --config /etc/caddy/Caddyfile` on VPS A. Don't restart the container — that drops connections.

## Follow-ups

- Document VPS B's IP + SSH access in a private (gitignored) ops doc.
- Add a Cloudflare Access policy for `lineage.danhle.net` matching what's used for `grafana.danhle.net`.
- Stand up a second `infra-mcp` instance pointed at VPS B so management symmetry isn't VPS-A-only.

## Links

- Caddy configuration: [../../caddy/Caddyfile](../../caddy/Caddyfile)
- Beacon stack (lives on VPS B): https://github.com/odanree/job-search-pipeline
- Lumen stack (lives on VPS B): private
- infra-mcp (manages VPS A only today): https://github.com/odanree/infra-mcp
