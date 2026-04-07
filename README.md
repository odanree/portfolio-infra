# Portfolio Infrastructure

Single Docker Compose stack that runs all portfolio projects on a shared Hetzner VPS (8GB RAM) behind a Caddy reverse proxy with automatic TLS.

## Architecture

```
Internet
    │ HTTPS (443)
    ▼
┌─────────────────────────────────────────────────────────┐
│  Caddy (auto TLS via Let's Encrypt)                     │
│  compensation-ingest.domain   → compensation-ingest-api │
│  compensation-explorer.domain → explorer-frontend       │
│                               ↘ /graphql/ → explorer-api│
│  shopify-erp.domain           → shopify-erp-app         │
│  shopify-orders.domain        → shopify-order-agent     │
│  shopify-inventory.domain     → shopify-inventory-agent │
│  shopify-metaobjects.domain   → metaobjects-webhook     │
└─────────────────────────────────────────────────────────┘
    │
    ▼  portfolio-net (internal bridge)
┌──────────────────────────────────────────────────────────┐
│  Shared Infrastructure                                   │
│  ┌─────────────────┐  ┌─────────────────┐               │
│  │ portfolio-postgres│  │ portfolio-redis  │              │
│  │ 4 databases      │  │ 4 logical DBs    │              │
│  └─────────────────┘  └─────────────────┘               │
└──────────────────────────────────────────────────────────┘

Redis DB allocation:
  db/0 → compensation-ingest (Celery broker + backend)
  db/1 → shopify-order-exception-agent
  db/2 → shopify-inventory-discrepancy-agent
  db/3 → (reserved)
```

## Estimated RAM usage on 8GB Hetzner box

| Component | Est. RSS |
|---|---|
| lumen1 stack (existing) | ~2.5 GB |
| portfolio-postgres | ~150 MB |
| portfolio-redis | ~50 MB |
| Caddy | ~30 MB |
| compensation-ingest-api + worker | ~400 MB |
| compensation-explorer-api + frontend | ~350 MB |
| shopify-erp-app | ~120 MB |
| shopify-order-agent + worker | ~350 MB |
| shopify-inventory-agent | ~250 MB |
| shopify-metaobjects-webhook | ~80 MB |
| OS + Docker overhead | ~800 MB |
| **Total** | **~5.1 GB** |

~2.9 GB headroom on the 8GB box.

## Prerequisites

All project repos must be checked out as siblings of this directory:

```
Projects/
├── portfolio-infra/          ← this repo
├── compensation-ingest-api/
├── compensation-benchmarking-explorer/
├── shopify-erp-integration/
├── shopify-order-exception-agent/
├── shopify-inventory-discrepancy-agent/
└── shopify-metaobjects-checkout-demo/
```

## Setup

### 1. Configure environment

```bash
cp .env.example .env
# Edit .env — set DOMAIN, CADDY_EMAIL, PORTFOLIO_DB_PASSWORD, and all API keys
```

### 2. Point DNS

Create A records for all six subdomains pointing to your Hetzner server IP:

```
compensation-ingest.yourdomain.com  → <hetzner-ip>
compensation-explorer.yourdomain.com → <hetzner-ip>
shopify-erp.yourdomain.com          → <hetzner-ip>
shopify-orders.yourdomain.com       → <hetzner-ip>
shopify-inventory.yourdomain.com    → <hetzner-ip>
shopify-metaobjects.yourdomain.com  → <hetzner-ip>
```

### 3. Build and start

```bash
# First time — builds all images, initializes databases, seeds data
docker compose up -d --build

# Check all containers are healthy
docker compose ps

# Follow logs
docker compose logs -f
```

### 4. Verify

```bash
# Should return 200
curl https://compensation-ingest.yourdomain.com/api/surveys/
curl https://compensation-explorer.yourdomain.com/graphql/
curl https://shopify-erp.yourdomain.com/health
curl https://shopify-orders.yourdomain.com/health
curl https://shopify-inventory.yourdomain.com/health
```

## Useful commands

```bash
# Rebuild a single service after a code change
docker compose up -d --build compensation-ingest-api

# Run Django management commands
docker compose exec compensation-ingest-api python manage.py createsuperuser
docker compose exec compensation-explorer-api python manage.py seed_bands

# Tail logs for one service
docker compose logs -f shopify-order-agent

# Connect to the shared database
docker compose exec postgres psql -U postgres -d compensation_ingest

# Check Redis
docker compose exec redis redis-cli -n 0 info keyspace
```

## Database init

The `init-db/` scripts run **once** when the postgres volume is first created:

- `00-create-user.sh` — creates `portfolio_user` with `$PORTFOLIO_DB_PASSWORD`
- `01-databases.sql` — creates the 4 databases and grants privileges

To reset and re-initialize (destructive):

```bash
docker compose down -v   # removes volumes
docker compose up -d --build
```

## Notes on Shopify Metaobjects

Only the **webhook server** (`app/server.js`) is deployed here. The checkout UI extension runs inside Shopify's infrastructure and is deployed separately via:

```bash
cd ../shopify-metaobjects-checkout-demo
shopify app deploy
```
