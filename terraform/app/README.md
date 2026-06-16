# App stack (Marquez + future oc-realestate-intel)

Compose files that get shipped to the Terraform-managed EC2.

## Files

- `docker-compose.yml` — Marquez (3 services) + Caddy. All on the `web` network so future stacks can attach via `external: true`.
- `Caddyfile` — TLS routes. `lineage.danhle.net` is live; `oci.danhle.net` is commented out and added in the next deploy round.

## Deploy (manual, until we automate)

After `terraform apply` finishes and you have the Elastic IP from `terraform output`:

```bash
# From this directory
EC2_IP=$(cd .. && terraform output -raw public_ip)
KEY=~/.ssh/marquez-key.pem

# Copy app files
scp -i "$KEY" -o StrictHostKeyChecking=no \
    docker-compose.yml Caddyfile \
    ubuntu@${EC2_IP}:/opt/app/

# SSH in and bring the stack up
ssh -i "$KEY" -o StrictHostKeyChecking=no ubuntu@${EC2_IP} \
    "cd /opt/app && docker compose up -d"
```

Then flip Cloudflare DNS for `lineage.danhle.net` A record from the old standalone EC2 IP to this Elastic IP. Caddy auto-issues the Let's Encrypt cert on first request.

## Verify

```bash
curl -sI https://lineage.danhle.net | head -3
curl -s https://lineage.danhle.net/api/v1/namespaces | python -m json.tool
```

The API listing should include the `beacon` namespace (carrying over from the previous Marquez instance) — note that on a brand-new Marquez DB it'll show `default` only until Beacon's worker emits its next event.

## Decommissioning the old standalone Marquez EC2

Once DNS is swapped and the new instance is serving:

```bash
# Find the old instance (originally named marquez-prod)
aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=marquez-prod" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,LaunchTime]' \
    --output table

# Terminate it
aws ec2 terminate-instances --instance-ids <old-instance-id>

# Release its Elastic IP (the one Beacon's worker was originally pointed at)
aws ec2 release-address --allocation-id <old-eip-alloc-id>
```

The new Terraform-managed instance has a new Elastic IP, so the old EIP can be released once nothing depends on it.
