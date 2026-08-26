terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    key = "ws-fleet/terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}
