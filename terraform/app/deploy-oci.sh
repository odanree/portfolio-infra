#!/bin/bash
# Deploy oc-realestate-intel to the Terraform-managed EC2.
#
# This script runs ON the EC2 (not locally) and:
#   1. Clones oc-realestate-intel into /home/ubuntu/oc-realestate-intel
#   2. Fetches secret values from AWS Secrets Manager via the instance role
#   3. Writes /opt/app/oci.env (gitignored, mode 600)
#   4. docker compose build + up for the oci stack
#   5. Reloads Caddy to pick up the oci.danhle.net block
#
# Idempotent — safe to re-run after `git pull` in either repo.

set -euo pipefail

REGION=${AWS_REGION:-us-east-1}
OCI_REPO=${OCI_REPO:-https://github.com/odanree/oc-realestate-intel.git}
OCI_CHECKOUT=/home/ubuntu/oc-realestate-intel
APP_DIR=/opt/app
ENV_FILE=${APP_DIR}/oci.env

echo "==> Cloning / updating oc-realestate-intel"
if [ -d "${OCI_CHECKOUT}/.git" ]; then
  cd "${OCI_CHECKOUT}" && git fetch origin && git reset --hard origin/master
else
  git clone "${OCI_REPO}" "${OCI_CHECKOUT}"
fi

echo "==> Fetching secrets from AWS Secrets Manager"
get_secret() {
  aws secretsmanager get-secret-value \
      --region "${REGION}" \
      --secret-id "$1" \
      --query SecretString \
      --output text
}

ANTHROPIC_API_KEY=$(get_secret marquez-oci/anthropic-api-key)
LANGFUSE_JSON=$(get_secret marquez-oci/langfuse)
LANGFUSE_PUBLIC_KEY=$(echo "${LANGFUSE_JSON}" | jq -r .public_key)
LANGFUSE_SECRET_KEY=$(echo "${LANGFUSE_JSON}" | jq -r .secret_key)
LANGFUSE_HOST=$(echo "${LANGFUSE_JSON}" | jq -r .host)
OCI_DB_PASSWORD=$(get_secret marquez-oci/oci-db-password)
OCI_NEO4J_PASSWORD=$(get_secret marquez-oci/oci-neo4j-password)

echo "==> Writing ${ENV_FILE}"
sudo mkdir -p "${APP_DIR}"
sudo tee "${ENV_FILE}" > /dev/null <<EOF
OCI_ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
OCI_LANGFUSE_PUBLIC_KEY=${LANGFUSE_PUBLIC_KEY}
OCI_LANGFUSE_SECRET_KEY=${LANGFUSE_SECRET_KEY}
OCI_LANGFUSE_HOST=${LANGFUSE_HOST}
OCI_DB_PASSWORD=${OCI_DB_PASSWORD}
OCI_NEO4J_PASSWORD=${OCI_NEO4J_PASSWORD}
EOF
sudo chown root:root "${ENV_FILE}"
sudo chmod 600 "${ENV_FILE}"

echo "==> Building + bringing up oci compose stack"
cd "${APP_DIR}"
sudo docker compose -f oci-compose.yml --env-file oci.env up -d --build

echo "==> Reloading Caddy (picks up oci.danhle.net block in updated Caddyfile)"
sudo docker exec caddy caddy reload --config /etc/caddy/Caddyfile || \
  sudo docker restart caddy

echo "==> Deployed. Watch the seed in oci-api logs:"
echo "    sudo docker logs -f oci-api"
