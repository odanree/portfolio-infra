terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "tf-state-portfolio-478818964123"
    key            = "marquez-oci/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "marquez-oci"
      ManagedBy = "Terraform"
      Repo      = "github.com/odanree/portfolio-infra"
    }
  }
}
