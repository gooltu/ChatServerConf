resource "aws_lb" "main" {
  name               = "jewelchat-prod"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

# WebSocket/BOSH traffic. Stickiness matters for BOSH's multiple discrete
# HTTP requests needing the same backend — WebSocket itself stays pinned
# to whichever target handled the upgrade for the life of the socket
# regardless, since ALB passes Upgrade/Connection headers through.
resource "aws_lb_target_group" "mongooseim" {
  name     = "mongooseim-tg"
  port     = 5280
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/http-bind"
    matcher             = "200-499" # BOSH responds to a bare GET with a client error, not 200 — any response at all means the listener is up
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }
}

# Stateless REST API — default round-robin, no stickiness needed.
resource "aws_lb_target_group" "nodeapp" {
  name     = "nodeapp-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.backend.certificate_arn

  # Anything not matching one of the two explicit host rules below (e.g.
  # the ALB's own raw AWS DNS name, or a stray probe) gets a flat 404
  # rather than silently landing on either backend.
  default_action {
    type = "fixed-response"
    fixed_response {
      status_code  = "404"
      content_type = "text/plain"
      message_body = "Not Found"
    }
  }
}

# Host-based routing — each backend has its own subdomain (see Context:
# jewelchat.net's bare apex is owned by a different AWS account's static
# site, so neither tier can live at the apex). MongooseIM's own auth.http
# call (userdata/mongooseim.sh.tpl) deliberately targets nodeapp_domain
# by name rather than the ALB's raw DNS name, specifically so it matches
# this rule explicitly instead of relying on default-action fallthrough.
resource "aws_lb_listener_rule" "mongooseim" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mongooseim.arn
  }

  condition {
    host_header {
      values = [var.mongooseim_domain]
    }
  }
}

resource "aws_lb_listener_rule" "nodeapp" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nodeapp.arn
  }

  condition {
    host_header {
      values = [var.nodeapp_domain]
    }
  }
}
