terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Created manually in ../BOOTSTRAP.md step 4 — a separate bucket/table
  # from infra/iam's, so infra-provisioner's own IAM policy can be scoped
  # to only this one without touching iam-admin's state.
  backend "s3" {
    bucket         = "jewelchat-tfstate-app-273426290822-ap-south-2-an"
    key            = "app/terraform.tfstate"
    region         = "ap-south-2"
    dynamodb_table = "jewelchat-tflock-app"
    encrypt        = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# CloudFront certificates must be requested in us-east-1 specifically,
# regardless of where the distribution's origin or everything else lives —
# an AWS-wide quirk, not a choice. Used only by static_site.tf's ACM cert.
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}
