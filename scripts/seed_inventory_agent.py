#!/usr/bin/env python3
"""Seed script for the Shopify Inventory Discrepancy Agent.

Sends a crafted inventory_levels/update webhook that triggers the full
human-in-the-loop workflow: detect → investigate → propose → (wait for approval).

The script uses `previous_quantity` as the baseline so no Redis setup is needed.
To use a Redis-pinned baseline instead, set one first:
    docker exec portfolio-redis redis-cli set inventory:baseline:{item_id}:{loc_id} 100

Usage:
    export SHOPIFY_INVENTORY_WEBHOOK_SECRET=your_secret
    export INVENTORY_AGENT_URL=https://shopify-inventory.yourdomain.com   # optional

    python seed_inventory_agent.py              # run default scenario
    python seed_inventory_agent.py --list       # list scenarios
    python seed_inventory_agent.py stockout     # run specific scenario
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import uuid

try:
    import httpx
except ImportError:
    print("Missing dependency: pip install httpx")
    sys.exit(1)

BASE_URL = os.getenv("INVENTORY_AGENT_URL", "https://shopify-inventory.danhle.net")
WEBHOOK_SECRET = os.getenv("SHOPIFY_INVENTORY_WEBHOOK_SECRET", "")
SHOP_DOMAIN = os.getenv("SHOPIFY_INVENTORY_STORE_DOMAIN", "demo-store.myshopify.com")


def _sign(body: bytes) -> str:
    if not WEBHOOK_SECRET:
        raise ValueError("SHOPIFY_INVENTORY_WEBHOOK_SECRET env var not set")
    digest = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).digest()
    return base64.b64encode(digest).decode()


def _headers(body: bytes) -> dict:
    return {
        "Content-Type": "application/json",
        "X-Shopify-Hmac-Sha256": _sign(body),
        "X-Shopify-Topic": "inventory_levels/update",
        "X-Shopify-Shop-Domain": SHOP_DOMAIN,
        "X-Shopify-Webhook-Id": str(uuid.uuid4()),
    }


def _payload(overrides: dict) -> dict:
    base = {
        "inventory_item_id": 44444444,
        "location_id": 55555555,
        "available": 60,
        "previous_quantity": 100,  # used as baseline if no Redis key set
        "sku": "DEMO-SKU-001",
        "updated_at": "2026-04-08T05:00:00-05:00",
        "admin_graphql_api_id": "gid://shopify/InventoryLevel/55555555?inventory_item_id=44444444",
    }
    base.update(overrides)
    return base


# ── Scenarios ─────────────────────────────────────────────────────────────────

SCENARIOS = {
    "shrinkage": {
        "description": "40% shrinkage (100→60) — moderate severity, triggers investigation",
        "payload": _payload({
            "inventory_item_id": 44444444,
            "location_id": 55555555,
            "available": 60,
            "previous_quantity": 100,
            "sku": "DEMO-SKU-001",
        }),
    },
    "stockout": {
        "description": "Near-total loss (100→5) — high severity, urgent investigation",
        "payload": _payload({
            "inventory_item_id": 44444445,
            "location_id": 55555555,
            "available": 5,
            "previous_quantity": 100,
            "sku": "DEMO-SKU-002",
        }),
    },
    "overstock": {
        "description": "Unexpected overstock (50→120) — possible receiving error",
        "payload": _payload({
            "inventory_item_id": 44444446,
            "location_id": 55555556,
            "available": 120,
            "previous_quantity": 50,
            "sku": "DEMO-SKU-003",
        }),
    },
    "below_threshold": {
        "description": "Small variance (100→96) — should be skipped (below threshold)",
        "payload": _payload({
            "inventory_item_id": 44444447,
            "location_id": 55555555,
            "available": 96,
            "previous_quantity": 100,
            "sku": "DEMO-SKU-004",
        }),
    },
}


def send(scenario_name: str, dry_run: bool = False) -> None:
    s = SCENARIOS[scenario_name]
    body = json.dumps(s["payload"]).encode()
    p = s["payload"]

    discrepancy_pct = abs(p["previous_quantity"] - p["available"]) / max(p["previous_quantity"], 1) * 100

    print(f"\n{'─' * 60}")
    print(f"  Scenario       : {scenario_name}")
    print(f"  {s['description']}")
    print(f"  SKU            : {p['sku']}")
    print(f"  Baseline       : {p['previous_quantity']}  →  Actual: {p['available']}")
    print(f"  Discrepancy    : {discrepancy_pct:.1f}%")
    print(f"  URL            : {BASE_URL}/api/webhooks/inventory-levels/update")

    if dry_run:
        print("  [dry-run] skipping HTTP request")
        return

    headers = _headers(body)

    try:
        with httpx.Client(timeout=15) as client:
            resp = client.post(
                f"{BASE_URL}/api/webhooks/inventory-levels/update",
                content=body,
                headers=headers,
            )
        print(f"  Status         : {resp.status_code}")
        try:
            data = resp.json()
            print(f"  Response       : {json.dumps(data, indent=2)}")
            if data.get("action") == "below_threshold":
                print("  ℹ️  Skipped — discrepancy below threshold (expected for this scenario)")
            elif data.get("status") == "accepted":
                print("  ✓ Workflow started — check dashboard and Slack for approval request")
                print(f"  Dashboard: {BASE_URL}/dashboard")
        except Exception:
            print(f"  Response       : {resp.text}")
    except Exception as exc:
        print(f"  ERROR          : {exc}")


def main():
    parser = argparse.ArgumentParser(
        description="Seed the Inventory Discrepancy Agent with a demo webhook"
    )
    parser.add_argument("scenarios", nargs="*", help="Scenario names to run (default: shrinkage)")
    parser.add_argument("--list", action="store_true", help="List available scenarios")
    parser.add_argument("--dry-run", action="store_true", help="Print details without sending")
    args = parser.parse_args()

    if args.list:
        print("Available scenarios:")
        for name, s in SCENARIOS.items():
            print(f"  {name:20} {s['description']}")
        return

    if not WEBHOOK_SECRET and not args.dry_run:
        print("ERROR: Set SHOPIFY_INVENTORY_WEBHOOK_SECRET env var")
        sys.exit(1)

    targets = args.scenarios if args.scenarios else ["shrinkage"]
    invalid = [t for t in targets if t not in SCENARIOS]
    if invalid:
        print(f"ERROR: Unknown scenarios: {invalid}")
        print(f"Valid: {list(SCENARIOS.keys())}")
        sys.exit(1)

    print(f"Inventory Discrepancy Agent seed — {BASE_URL}")
    print(f"Scenarios: {targets}")
    print()
    print("After sending, the agent will:")
    print("  1. Detect the discrepancy")
    print("  2. Investigate (query Shopify for orders, locations)")
    print("  3. Propose a resolution")
    print("  4. PAUSE and send a Slack approval request")
    print("  5. Wait for you to Approve/Reject in Slack or via /dashboard")

    for name in targets:
        send(name, dry_run=args.dry_run)
        time.sleep(2)

    print(f"\n{'─' * 60}")
    print(f"Done. Monitor at: {BASE_URL}/dashboard")


if __name__ == "__main__":
    main()
