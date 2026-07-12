output "instance_id" {
  description = "EC2 instance ID for the marquez-oci host."
  value       = aws_instance.marquez_oci.id
}

output "public_ip" {
  description = "Elastic IP — point Cloudflare DNS A records here (lineage.{domain}, oci.{domain})."
  value       = aws_eip.instance.public_ip
}

output "ssh_command" {
  description = "Ready-to-paste SSH command. Assumes the key file is at ~/.ssh/<key_pair_name>.pem."
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ubuntu@${aws_eip.instance.public_ip}"
}

output "secrets_arns" {
  description = "Secrets Manager ARNs. Populate values with `aws secretsmanager put-secret-value`."
  value = {
    anthropic          = aws_secretsmanager_secret.anthropic_api_key.arn
    langfuse           = aws_secretsmanager_secret.langfuse.arn
    oci_db_password    = aws_secretsmanager_secret.oci_db_password.arn
    oci_neo4j_password = aws_secretsmanager_secret.oci_neo4j_password.arn
  }
}

output "instance_profile" {
  description = "IAM instance profile name attached to the box."
  value       = aws_iam_instance_profile.instance.name
}

# ─── beacon-cdc-listener (ADR-021 phase 3b) ──────────────────────────

output "beacon_cdc_ecr_repository_url" {
  description = "ECR repo URL for the CDC listener image. CI push target: `<url>:latest` and `<url>:<git-sha>`."
  value       = aws_ecr_repository.beacon_cdc_listener.repository_url
}

output "beacon_cdc_secrets_arns" {
  description = "Secrets Manager ARNs for the CDC listener. Populate values with `aws secretsmanager put-secret-value`."
  value = {
    database_url      = aws_secretsmanager_secret.beacon_cdc_database_url.arn
    ssh_key           = aws_secretsmanager_secret.beacon_cdc_ssh_key.arn
    vercel_deploy_hook = aws_secretsmanager_secret.beacon_cdc_vercel_deploy_hook.arn
  }
}

output "beacon_cdc_cluster_name" {
  description = "ECS cluster name for the CDC listener service. Useful for `aws ecs update-service` scaling operations."
  value       = aws_ecs_cluster.cdc.name
}

output "beacon_cdc_service_name" {
  description = "ECS service name for the CDC listener. Useful for CloudWatch Container Insights + manual scaling."
  value       = aws_ecs_service.cdc_listener.name
}

output "beacon_cdc_log_group" {
  description = "CloudWatch Log Group holding listener stdout/stderr. Tail with `aws logs tail /ecs/marquez-oci-cdc-listener --follow`."
  value       = aws_cloudwatch_log_group.cdc_listener.name
}

# ─── GitHub Actions OIDC ────────────────────────────────────────────

output "gh_actions_beacon_mcp_role_arn" {
  description = "Role ARN for beacon-mcp GitHub Actions to assume via OIDC. Paste into .github/workflows/build-listener-image.yml as `role-to-assume`."
  value       = aws_iam_role.gh_actions_beacon_mcp.arn
}
