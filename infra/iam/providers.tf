terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Created manually in BOOTSTRAP.md step 4, by root, before this module
  # is ever run. Scoped so this state's own identity (iam-admin) can only
  # touch this one bucket/table — never infra/app's.
  backend "s3" {
    bucket         = "jewelchat-tfstate-iam-273426290822-ap-south-2-an"
    key            = "iam/terraform.tfstate"
    region         = "ap-south-2"
    dynamodb_table = "jewelchat-tflock-iam"
    encrypt        = true
  }
}

# Run as: terraform apply -var-file=... --  (profile selected via AWS_PROFILE=iam-admin
# or `aws_profile` variable below — either works, pick one convention and stay
# consistent so it's never accidentally run as the wrong identity).
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
