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
