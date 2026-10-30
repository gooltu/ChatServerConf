resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "jewelchat-prod" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "jewelchat-prod" }
}

# Public subnets — ALB only.
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true
  tags                    = { Name = "jewelchat-public-${var.availability_zones[count.index]}" }
}

# RDS only now (MongooseIM/Node app EC2 moved to the public subnets below —
# see asg_mongooseim.tf/asg_nodeapp.tf). No route table association of its
# own: falls back to the VPC's implicit default route table, which only
# has the local 10.20.0.0/16 route — RDS has no need for a path out, and
# this means it's unreachable from the internet at the routing level, not
# just via publicly_accessible=false/security groups (defense in depth).
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  tags              = { Name = "jewelchat-private-${var.availability_zones[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "jewelchat-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway deliberately removed (2026-10-07): its $0.056/hr base charge
# alone was the single largest recurring line item in this whole stack —
# more than the ALB, both EC2 instances, and RDS combined (see cost
# breakdown discussion). MongooseIM/Node app EC2 moved to the public
# subnets instead (asg_mongooseim.tf/asg_nodeapp.tf): a plain Internet
# Gateway route costs nothing per-hour and nothing per-GB on top of normal
# data-transfer-out pricing (NAT's per-GB "processing" fee was on top of
# that, not instead of it). Security boundary is now security groups alone
# — acceptable here because `mongooseim-sg`/`nodeapp-sg` (security_groups.tf)
# were already minimal before this change: no SSH, no inbound management
# ports, only the specific ALB/inter-tier ports they need. RDS stays on the
# private subnets above with no internet route at all, regardless of this
# change.
