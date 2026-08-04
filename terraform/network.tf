# Default VPC + default subnet lookups. Shared by the beacon-cdc Fargate
# listener (see beacon-cdc.tf) — the marquez-oci EC2 that historically also
# used these was decommissioned when OCI migrated to the Hetzner VPS.
# Real multi-environment setups would create a dedicated VPC per env;
# portfolio scale doesn't need it.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}
