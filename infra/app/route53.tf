resource "aws_route53_zone" "main" {
  name              = var.domain_name
  delegation_set_id = var.route53_delegation_set_id
}

# ALB's own cert — ap-south-2 is fine here (ALB certs just need to be in
# the ALB's own region, unlike CloudFront's us-east-1 requirement).
resource "aws_acm_certificate" "backend" {
  domain_name               = var.mongooseim_domain
  subject_alternative_names = [var.nodeapp_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "backend_acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.backend.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = aws_route53_zone.main.id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}

resource "aws_acm_certificate_validation" "backend" {
  certificate_arn         = aws_acm_certificate.backend.arn
  validation_record_fqdns = [for r in aws_route53_record.backend_acm_validation : r.fqdn]
}

# ALIAS (not CNAME) — Route53-specific, free queries, and the only way to
# point a name at an AWS resource like an ALB without pinning its
# sometimes-changing underlying IPs.
resource "aws_route53_record" "mongooseim" {
  zone_id = aws_route53_zone.main.id
  name    = var.mongooseim_domain
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "nodeapp" {
  zone_id = aws_route53_zone.main.id
  name    = var.nodeapp_domain
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
