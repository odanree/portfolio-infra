# Secrets Manager entries — created here so the IAM policy can grant access
# under a stable ARN prefix (marquez-oci/*). Values are NOT written by
# Terraform — populate them out-of-band with `aws secretsmanager put-secret-value`,
# which keeps them out of `terraform.tfstate` (state is encrypted, but secret
# material doesn't belong there at all).
#
# Populate after `terraform apply` with:
#   aws secretsmanager put-secret-value \
#       --secret-id marquez-oci/anthropic-api-key \
#       --secret-string sk-ant-xxx
#   aws secretsmanager put-secret-value \
#       --secret-id marquez-oci/langfuse \
#       --secret-string '{"public_key":"pk-...","secret_key":"sk-...","host":"https://us.cloud.langfuse.com"}'

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name                    = "${var.tag_name}/anthropic-api-key"
  description             = "Anthropic API key for oc-realestate-intel agent + evaluator"
  recovery_window_in_days = 0 # immediate hard-delete on terraform destroy; safe because we set values out-of-band
}

resource "aws_secretsmanager_secret" "langfuse" {
  name                    = "${var.tag_name}/langfuse"
  description             = "Langfuse public + secret keys + host (JSON)"
  recovery_window_in_days = 0
}

# oc-realestate-intel-specific secrets — Postgres password + Neo4j password.
# Generated locally and put-secret-value'd in after `terraform apply`.
resource "aws_secretsmanager_secret" "oci_db_password" {
  name                    = "${var.tag_name}/oci-db-password"
  description             = "oc-realestate-intel Postgres password (random; rotated by operator)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "oci_neo4j_password" {
  name                    = "${var.tag_name}/oci-neo4j-password"
  description             = "oc-realestate-intel Neo4j password"
  recovery_window_in_days = 0
}
