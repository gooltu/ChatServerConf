# Static site for the bare apex (jewelchat.net) — now hosted in this
# account instead of the other one. Bucket stays fully private; CloudFront
# reaches it via Origin Access Control (OAC), the current recommended
# mechanism (OAI is the older, now-discouraged one). Placeholder content
# only for now — real content migration is a separate later step.
#
# Bucket itself is created manually by the user (console), not by
# Terraform — infra-provisioner deliberately has no s3:CreateBucket
# permission. Referenced here as a data source (read-only lookup) so
# everything downstream (policy, OAC, CloudFront origin) can still be
# managed in code without Terraform ever owning the bucket's lifecycle.
data "aws_s3_bucket" "site" {
  bucket = var.site_bucket_name
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = data.aws_s3_bucket.site.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "placeholder_index" {
  bucket       = data.aws_s3_bucket.site.id
  key          = "index.html"
  content_type = "text/html"
  content      = <<-EOF
    <!doctype html>
    <html>
      <head><title>jewelchat.net</title></head>
      <body><h1>jewelchat.net</h1><p>Site coming soon.</p></body>
    </html>
  EOF
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "jewelchat-site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront certs must be requested in us-east-1 regardless of where
# everything else runs — see providers.tf's aws.us_east_1 alias.
resource "aws_acm_certificate" "site" {
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "site_acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "site" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.site_acm_validation : r.fqdn]
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = [var.domain_name]
  price_class         = "PriceClass_100" # cheapest tier (NA/EU edge locations) — fine for a low-traffic placeholder site

  origin {
    domain_name              = data.aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "site-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed "CachingOptimized"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = data.aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${data.aws_s3_bucket.site.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.site.arn
        }
      }
    }]
  })
}

resource "aws_route53_record" "apex_site" {
  zone_id = aws_route53_zone.main.id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}
