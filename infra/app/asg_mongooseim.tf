data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# Created by iam-admin's Terraform run (infra/iam) — looked up here, never
# a resource, per the IAM two-identity split in plan §2.
data "aws_iam_instance_profile" "mongooseim" {
  name = "mongooseim-runtime-profile"
}

locals {
  mongooseim_asg_name = "mongooseim-asg"
}

resource "aws_launch_template" "mongooseim" {
  name_prefix   = "mongooseim-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.mongooseim_instance_type

  iam_instance_profile {
    name = data.aws_iam_instance_profile.mongooseim.name
  }

  # Public subnet + public IP now (NAT removed, see vpc.tf) — security_groups
  # must live inside network_interfaces once associate_public_ip_address is
  # set here; the AWS provider rejects mixing this with a top-level
  # vpc_security_group_ids on the same launch template.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.mongooseim.id]
  }

  user_data = base64encode(templatefile("${path.module}/userdata/mongooseim.sh.tpl", {
    region         = var.aws_region
    rds_endpoint   = aws_db_instance.main.address
    nodeapp_domain = var.nodeapp_domain
    asg_name       = local.mongooseim_asg_name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "mongooseim" }
  }
}

resource "aws_autoscaling_group" "mongooseim" {
  name                = local.mongooseim_asg_name
  vpc_zone_identifier = aws_subnet.public[*].id

  # Intended steady state is 1 (self-healing), built for clustering from
  # day one — raise desired_capacity one instance at a time when load grows
  # (plan §5 race-avoidance caveat). Variable (not hardcoded 1, matching
  # nodeapp's pattern) so this ASG can be deliberately idled at 0 — e.g.
  # between infra changes, before MongooseIM is actually ready to launch —
  # without editing this file; default is the intended steady state.
  min_size         = var.mongooseim_desired_capacity
  max_size         = var.mongooseim_max_capacity
  desired_capacity = var.mongooseim_desired_capacity

  launch_template {
    id      = aws_launch_template.mongooseim.id
    version = "$Latest"
  }

  target_group_arns         = [aws_lb_target_group.mongooseim.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  tag {
    key                 = "Name"
    value               = "mongooseim"
    propagate_at_launch = true
  }
}
