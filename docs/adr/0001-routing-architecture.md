# ADR-0001: Single-host architecture with portfolio-caddy as the single ingress

- **Status:** Accepted
- **Date:** 2026-06-15
- **Deciders:** Danh Le

## Context

Almost everything portfolio-related runs on **one Hetzner host** (`65.108.243.192`), but the running services are spread across **multiple independent docker-compose projects** — portfolio-infra, Beacon, Lumen, ADU, and others — each in its own repo, each deployed separately. They share a docker network so `portfolio-caddy` can reverse-proxy across project boundaries.

This is non-obvious from reading the Caddyfile alone. A reviewer who runs `docker ps` against the portfolio-infra compose project sees ~22 containers and notices that the Caddyfile contains routes like `reverse_proxy beacon-frontend:3000` pointing to containers that aren't in that list. Without this ADR, the natural conclusion is *"those routes must be cross-host"* — they're not. They're cross-compose-project on the same host.

## Current state

```
                          Cloudflare DNS + proxy
                                   │
                                   ▼
                       ┌─────────────────────────┐
                       │  portfolio-caddy        │
                       │  (the only public TLS   │
                       │  termination point)     │
                       └─────────────┬───────────┘
                                     │
                                     ▼
                     shared docker network on Hetzner host
                                     │
        ┌──────────────────┬─────────┴─────────┬──────────────────┐
        ▼                  ▼                   ▼                  ▼
  ┌──────────┐     ┌──────────────┐    ┌─────────────┐    ┌─────────────┐
  │ portfolio│     │ Beacon       │    │ Lumen       │    │ Other       │
  │ -infra   │     │ compose      │    │ compose     │    │ apps        │
  │ compose  │     │              │    │             │    │             │
  │          │     │ beacon-*     │    │ lumen-*     │    │ adu-*       │
  │ oci-*    │     │ beacon-mar-  │    │             │    │ parking-det │
  │ shopify-*│     │   quez-*     │    │             │    │             │
  │ compen-* │     │              │    │             │    │             │
  │ port-*   │     │              │    │             │    │             │
  │ wordpress│     │              │    │             │    │             │
  │ caddy    │     │              │    │             │    │             │
  └──────────┘     └──────────────┘    └─────────────┘    └─────────────┘
```

Two domains live elsewhere:

- **`shop.danhle.net`** — DigitalOcean droplet `159.203.94.25`. The Shopify metaobjects checkout demo. Not behind portfolio-caddy.
- **`jsp.danhle.net`** — Cloudflare Tunnel `jobsearch-pipeline`. Separate from `beacon.danhle.net` (which lives on the Hetzner host alongside the others).

Everything else is one host.

## Decision

Two layers, separately scoped:

### Layer 1 — Routing & TLS (centralized in `portfolio-infra`)

- **One Caddy** (`portfolio-caddy`) handles TLS + reverse-proxy for every `*.danhle.net` subdomain on the Hetzner host.
- **All subdomain routes** live in `portfolio-infra/caddy/Caddyfile` regardless of which compose project owns the target container. Adding a new route is a portfolio-infra PR.
- **TLS certs** auto-managed via Let's Encrypt.
- **Cloudflare Access** is the auth layer for protected subdomains (e.g. `lineage.danhle.net`, internal dashboards). Caddy serves an open backend; CF Access in front gates browser access. This avoids managing basic-auth hashes in the Caddyfile.

### Layer 2 — App services (per-app compose stacks)

- Each app owns its **own `docker-compose.yml`** in its own repo (Beacon: `job-search-pipeline`; Lumen: `lumen`; etc).
- Apps **join the shared docker network** declared external in their compose, so `portfolio-caddy` can resolve their container names. Service name = hostname inside the network.
- Apps **never** edit portfolio-infra's Caddyfile inside their own compose. They expose a container, and the Caddyfile here proxies to it.

### Why multiple compose projects, not one mega-compose

If everything moved into portfolio-infra's compose, it'd be a 50+ service file with conflicting envs, no app-level isolation, and PRs from every app would land in one repo. The current split keeps each app reviewable in isolation while centralizing the only thing that genuinely benefits from being central: the public ingress.

### Why one host (mostly), not many

The portfolio doesn't have the load to need multi-host orchestration. One right-sized Hetzner box runs all of it with headroom. The DO droplet exists for historical/contractual reasons (the Shopify demo customer has its own deploy). The Cloudflare Tunnel for `jsp.danhle.net` is a single-purpose external entrypoint, separate concern.

## Consequences

**Positive**
- One file to grep when answering *"where does `foo.danhle.net` go?"* — this Caddyfile.
- Per-app composes stay reviewable, deployable, and rollback-able independently.
- Adding a route for a new service is one PR + one `caddy_reload`.
- No cross-host networking complexity. The "overlay" is just docker network sharing on one box.

**Negative**
- The Caddyfile contains hostnames for containers that **aren't in portfolio-infra's compose** — confusing without this ADR. Every cross-project route needs a comment pointing at this doc.
- One host = single failure domain. If the Hetzner box goes down, the whole portfolio goes down.
- `infra-mcp` only sees portfolio-infra's compose project. To inspect Beacon/Lumen/ADU/etc, SSH in directly.
- The shared docker network is created out-of-band (not in portfolio-infra/docker-compose.yml). New apps have to know to join it.

## Alternatives considered

- **Move all apps into portfolio-infra's compose** — rejected. See "Why multiple compose projects" above.
- **Run a Caddy per app** — rejected. Multiple Caddies = multiple TLS-cert lifecycles, no single source of truth for routes.
- **Migrate everything to k8s / Nomad / Swarm** — overkill for this scale. Re-evaluate if/when load exceeds one box.
- **Move Beacon onto its own host for failure isolation** — possible but adds operational surface for limited benefit at current scale. Worth revisiting if Beacon's churn becomes a stability concern for the rest of the portfolio.

## Rules going forward

1. **New route → portfolio-infra PR.** Even if the target container is owned by another compose project, the Caddy block lives here.
2. **Comment every cross-project route.** If the target container isn't in portfolio-infra's compose, add a one-line comment naming the compose project that owns it, so the next reader doesn't go grepping for a ghost.
3. **Auth via Cloudflare Access**, not Caddy basicauth. Caddy serves an open backend; CF Access policy gates browser traffic.
4. **App composes stay in app repos.** Don't smuggle app services into portfolio-infra/docker-compose.yml; it's reserved for infra-level services (portfolio-caddy, portfolio-postgres, portfolio-redis, the WordPress CMS, monitoring).
5. **Shared network membership** — every app compose declares the shared docker network as external. Document the network name in the app's README.
6. **Caddy reload** is via the `caddy_reload_tool` MCP or `docker exec portfolio-caddy caddy reload --config /etc/caddy/Caddyfile` on the host. Don't restart the container — that drops connections.

## Follow-ups

- Add a Cloudflare Access policy for `lineage.danhle.net` matching what's used for `grafana.danhle.net`.
- Document the shared docker network's name + how to join it in a README in this repo.
- Audit which subdomain routes in this Caddyfile are still active vs left over (e.g. `grafana-lumen` is a redirect — is the source still live?).

## Links

- Caddy configuration: [../../caddy/Caddyfile](../../caddy/Caddyfile)
- Beacon stack (separate compose, same host): https://github.com/odanree/job-search-pipeline
- Lumen stack (separate compose, same host): private
- infra-mcp (sees portfolio-infra compose project only): https://github.com/odanree/infra-mcp
