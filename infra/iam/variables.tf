variable "aws_region" {
  type    = string
  default = "ap-south-2"
}

# Must resolve to the `iam-admin` identity from BOOTSTRAP.md — this module
# has no provisioning power, but it's still the wrong identity to run
# infra/app under, and vice versa. Keep the two profiles distinct locally.
variable "aws_profile" {
  type    = string
  default = "iam-admin"
}

variable "account_id" {
  type        = string
  description = "AWS account ID — used to build secret/log-group ARNs without a data source round-trip."
}
