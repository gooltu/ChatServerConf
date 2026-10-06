variable "aws_region" {
  type    = string
  default = "ap-south-2"
}

# Must resolve to the `infra-provisioner` identity from ../BOOTSTRAP.md.
variable "aws_profile" {
  type    = string
  default = "infra-provisioner"
}

variable "account_id" {
  type        = string
  description = "AWS account ID — used to build the data-source lookups for the IAM roles iam-admin already created."
}

variable "domain_name" {
  type    = string
  default = "jewelchat.net"
}

# Created manually by the user via console, not by Terraform — see the
# data source comment in static_site.tf for why.
variable "site_bucket_name" {
  type    = string
  default = "jewelchat-site-prod-273426290822"
}

# Created once via `aws route53 create-reusable-delegation-set` (not by
# Terraform — it's meant to outlive this zone's own lifecycle). BigRock's
# nameservers for jewelchat.net point at this delegation set's 4 NS
# values; referencing the same ID here means destroying and recreating
# the hosted zone never requires touching BigRock again.
# Bare ID only — the aws_route53_zone resource's delegation_set_id
# argument rejects the "/delegationset/" prefix the CLI/API otherwise
# returns it wrapped in.
variable "route53_delegation_set_id" {
  type    = string
  default = "N05666861GSRJT1YQHDGK"
}

variable "mongooseim_domain" {
  type    = string
  default = "chat.jewelchat.net"
}

variable "nodeapp_domain" {
  type    = string
  default = "game.jewelchat.net"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-south-2a", "ap-south-2b"]
}

# Smallest to start (per user's explicit "smallest EC2 servers for now") —
# resize later via a new launch template version + ASG instance refresh,
# no architectural change needed.
variable "mongooseim_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "nodeapp_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

# Fixed at 2 for now (no autoscaling policy yet) — adjust manually as real
# load data comes in, per plan §5.
variable "nodeapp_desired_capacity" {
  type    = number
  default = 2
}

# Room to grow without redesigning the clustering mechanism (plan §5) —
# starts at 1, raise desired_capacity one instance at a time when needed.
variable "mongooseim_max_capacity" {
  type    = number
  default = 5
}
