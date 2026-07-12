variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium gives 4 GB RAM, enough for Marquez + oc-realestate-intel under modest load."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GiB. Holds OS + docker images + named-volume data for Postgres / Qdrant / Neo4j / Marquez."
  type        = number
  default     = 60
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair to attach for SSH access. Create with `aws ec2 create-key-pair --key-name <name> > <name>.pem`."
  type        = string
  default     = "marquez-key"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH to the instance. Defaults to anywhere — override per-environment for production."
  type        = string
  default     = "0.0.0.0/0"
}

variable "tag_name" {
  description = "Value of the Name tag on the EC2 instance + Elastic IP."
  type        = string
  default     = "marquez-oci"
}

# ─── beacon-cdc-listener (ADR-021 phase 3b) ──────────────────────────

variable "cdc_listener_image_tag" {
  description = "Image tag pushed to the beacon-cdc-listener ECR repo. Follows semver for tagged releases; CI pushes `latest` + git SHA on merge to master. Update this and re-apply to roll the service."
  type        = string
  default     = "latest"
}

variable "cdc_listener_desired_count" {
  description = "Desired number of always-on Fargate tasks for the CDC listener. Set 0 during initial bootstrap (before the first image is in ECR) or during maintenance windows. Set 1 to activate the listener. Higher values don't help — LISTEN state is per-connection and every task would independently rebuild on every NOTIFY."
  type        = number
  default     = 0
}
