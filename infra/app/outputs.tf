output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "rds_master_secret_arn" {
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
  description = "AWS-managed master credentials secret — used only for the one-time bootstrap in BOOTSTRAP.md/plan §3, never by the app roles."
}

output "ecr_repository_url" {
  value = aws_ecr_repository.serverprojectx.repository_url
}

output "hosted_zone_id" {
  value = aws_route53_zone.main.id
}

output "hosted_zone_name_servers" {
  value       = aws_route53_zone.main.name_servers
  description = "Should match the 4 nameservers already given to BigRock (tied to the reusable delegation set) — if these ever differ, something's wrong."
}

output "site_bucket_name" {
  value = data.aws_s3_bucket.site.id
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.site.id
}
