data "aws_iam_instance_profile" "nodeapp" {
  name = "nodeapp-runtime-profile"
}

resource "aws_launch_template" "nodeapp" {
  name_prefix   = "nodeapp-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.nodeapp_instance_type

  iam_instance_profile {
    name = data.aws_iam_instance_profile.nodeapp.name
  }

  vpc_security_group_ids = [aws_security_group.nodeapp.id]

  user_data = base64encode(templatefile("${path.module}/userdata/nodeapp.sh.tpl", {
    region             = var.aws_region
    rds_endpoint       = aws_db_instance.main.address
    ecr_repository_url = aws_ecr_repository.serverprojectx.repository_url
    ecr_registry_url   = split("/", aws_ecr_repository.serverprojectx.repository_url)[0]
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "nodeapp" }
  }
}

resource "aws_autoscaling_group" "nodeapp" {
  name                = "nodeapp-asg"
  vpc_zone_identifier = aws_subnet.private[*].id

  # Fixed at nodeapp_desired_capacity for now (no scaling policy yet) —
  # real horizontal scaling, unlike MongooseIM's tier. Adjust manually as
  # real load data comes in (plan §5).
  min_size         = var.nodeapp_desired_capacity
  max_size         = var.nodeapp_desired_capacity
  desired_capacity = var.nodeapp_desired_capacity

  launch_template {
    id      = aws_launch_template.nodeapp.id
    version = "$Latest"
  }

  target_group_arns         = [aws_lb_target_group.nodeapp.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 90

  tag {
    key                 = "Name"
    value               = "nodeapp"
    propagate_at_launch = true
  }
}
