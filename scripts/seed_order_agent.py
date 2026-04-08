#!/usr/bin/env python3
"""Seed script for the Shopify Order Exception Agent.

Sends crafted order webhook payloads that trigger each exception branch.
Computes valid HMAC-SHA256 signatures so the agent accepts them.

Usage:
    export SHOPIFY_ORDER_WEBHOOK_SECRET=your_secret
    export ORDER_AGENT_URL=https://shopify-orders.yourdomain.com   # optional

    python seed_order_agent.py              # run all scenarios
    python seed_order_agent.py fraud        # run one scenario
    python seed_order_agent.py --list       # list available scenarios
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

BASE_URL = os.getenv("ORDER_AGENT_URL", "https://shopify-orders.danhle.net")
WEBHOOK_SECRET = os.getenv("SHOPIFY_ORDER_WEBHOOK_SECRET", "")
SHOP_DOMAIN = os.getenv("SHOPIFY_ORDER_STORE_DOMAIN", "demo-store.myshopify.com")


def _sign(body: bytes) -> str:
    if not WEBHOOK_SECRET:
        raise ValueError("SHOPIFY_ORDER_WEBHOOK_SECRET env var not set")
    digest = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).digest()
    return base64.b64encode(digest).decode()


def _headers(body: bytes, topic: str) -> dict:
    return {
        "Content-Type": "application/json",
        "X-Shopify-Hmac-Sha256": _sign(body),
        "X-Shopify-Topic": topic,
        "X-Shopify-Shop-Domain": SHOP_DOMAIN,
        "X-Shopify-Webhook-Id": str(uuid.uuid4()),
    }


def _order(overrides: dict) -> dict:
    base = {
        "id": int(time.time() * 1000) % 10_000_000,
        "name": f"#DEMO-{int(time.time()) % 10000}",
        "created_at": "2026-04-08T00:00:00-05:00",
        "total_price": "89.99",
        "financial_status": "paid",
        "fulfillment_status": None,
        "risk_level": "low",
        "tags": "",
        "shipping_address": {
            "first_name": "Demo",
            "last_name": "Customer",
            "address1": "123 Main St",
            "city": "Chicago",
            "province": "Illinois",
            "country": "United States",
            "zip": "60601",
        },
        "line_items": [
            {"title": "Demo Product", "quantity": 1, "price": "89.99", "sku": "DEMO-001"}
        ],
        "customer": {"id": 99999, "email": "demo@example.com"},
    }
    base.update(overrides)
    return base


# ── Scenarios ─────────────────────────────────────────────────────────────────

SCENARIOS = {
    "fraud": {
        "description": "High fraud risk → triage:fraud_risk → tag + Slack + hold fulfillment",
        "topic": "orders/create",
        "path": "/api/webhooks/orders/create",
        "payload": _order({
            "id": 1001001,
            "total_price": "349.00",
            "risk_level": "high",
            "financial_status": "paid",
            "tags": "high-risk",
            "shipping_address": {
                "first_name": "John",
                "last_name": "Smith",
                "address1": "742 Evergreen Terrace",
                "city": "Springfield",
                "province": "Illinois",
                "country": "United States",
                "zip": "62701",
            },
            "note": "Rush order, ship today no matter what",
        }),
    },
    "address": {
        "description": "Invalid address → triage:address_invalid → tag + Slack",
        "topic": "orders/create",
        "path": "/api/webhooks/orders/create",
        "payload": _order({
            "id": 1001002,
            "total_price": "54.99",
            "shipping_address": {
                "first_name": "Jane",
                "last_name": "Doe",
                "address1": "",
                "city": "",
                "province": "",
                "country": "Unknown",
                "zip": "00000",
            },
        }),
    },
    "payment": {
        "description": "Payment issue → triage:payment_issue → escalate to Slack",
        "topic": "orders/updated",
        "path": "/api/webhooks/orders/updated",
        "payload": _order({
            "id": 1001003,
            "total_price": "199.00",
            "financial_status": "payment_pending",
            "tags": "payment-failed,retry-attempted",
            "note": "Card declined twice. Customer notified.",
        }),
    },
    "high_value": {
        "description": "High-value order ($1200) → overrides routing → manual review required",
        "topic": "orders/create",
        "path": "/api/webhooks/orders/create",
        "payload": _order({
            "id": 1001004,
            "total_price": "1249.99",
            "financial_status": "paid",
            "line_items": [
                {"title": "Premium Bundle", "quantity": 1, "price": "1249.99", "sku": "PREM-001"}
            ],
        }),
    },
    "fulfillment": {
        "description": "Fulfillment delay → triage:fulfillment_delay → tag + 3PL notify",
        "topic": "fulfillments/updated",
        "path": "/api/webhooks/fulfillments/updated",
        "payload": {
            "id": 9001001,
            "order_id": 1001005,
            "status": "in_transit",
            "created_at": "2026-03-25T10:00:00-05:00",
            "updated_at": "2026-04-08T10:00:00-05:00",
            "tracking_number": "1Z999AA10123456784",
            "tracking_company": "UPS",
            "shipment_status": "delayed",
        },
    },
}


def send(scenario_name: str, dry_run: bool = False) -> None:
    s = SCENARIOS[scenario_name]
    body = json.dumps(s["payload"]).encode()

    print(f"\n{'─' * 60}")
    print(f"  Scenario : {scenario_name}")
    print(f"  {s['description']}")
    print(f"  URL      : {BASE_URL}{s['path']}")
    print(f"  Order ID : {s['payload'].get('id') or s['payload'].get('order_id')}")

    if dry_run:
        print("  [dry-run] skipping HTTP request")
        return

    headers = _headers(body, s["topic"])

    try:
        with httpx.Client(timeout=15) as client:
            resp = client.post(f"{BASE_URL}{s['path']}", content=body, headers=headers)
        print(f"  Status   : {resp.status_code}")
        print(f"  Response : {resp.text}")
    except Exception as exc:
        print(f"  ERROR    : {exc}")


def main():
    parser = argparse.ArgumentParser(description="Seed the Order Exception Agent with demo webhooks")
    parser.add_argument("scenarios", nargs="*", help="Scenario names to run (default: all)")
    parser.add_argument("--list", action="store_true", help="List available scenarios")
    parser.add_argument("--dry-run", action="store_true", help="Print payloads without sending")
    args = parser.parse_args()

    if args.list:
        print("Available scenarios:")
        for name, s in SCENARIOS.items():
            print(f"  {name:15} {s['description']}")
        return

    if not WEBHOOK_SECRET and not args.dry_run:
        print("ERROR: Set SHOPIFY_ORDER_WEBHOOK_SECRET env var")
        sys.exit(1)

    targets = args.scenarios if args.scenarios else list(SCENARIOS.keys())
    invalid = [t for t in targets if t not in SCENARIOS]
    if invalid:
        print(f"ERROR: Unknown scenarios: {invalid}")
        print(f"Valid: {list(SCENARIOS.keys())}")
        sys.exit(1)

    print(f"Order Exception Agent seed — {BASE_URL}")
    print(f"Scenarios: {targets}")

    for name in targets:
        send(name, dry_run=args.dry_run)
        time.sleep(1)  # small gap so background tasks don't collide

    print(f"\n{'─' * 60}")
    print("Done. Check the dashboard: " + BASE_URL + "/dashboard")


if __name__ == "__main__":
    main()
