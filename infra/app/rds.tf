resource "aws_db_subnet_group" "main" {
  name       = "jewelchat-prod"
  subnet_ids = aws_subnet.private[*].id
}

# One instance, two databases (mongooseim + gameserver) — matches the
# current single mysql-db container exactly, not split per plan's RDS
# decision. Single-AZ, smallest class to start.
#
# Master credentials are AWS-managed (manage_master_user_password) — never
# a Terraform variable/state value. The app-level `mongooseim` and
# `gameserver` database users (least-privilege, matching the existing dev
# pattern) are created manually during the one-time bootstrap in ../BOOTSTRAP.md
# / plan §3, with their credentials stored directly into the
# `mongooseim/db-credentials` and `serverprojectx/db-credentials` Secrets
# Manager secrets that the two runtime roles read at boot.
resource "aws_db_instance" "main" {
  identifier = "jewelchat-prod"
  engine     = "mysql"
  # 8.0 is RDS's deprecated track (support window closing); 8.4 is the
  # current LTS release — confirmed via `aws rds describe-db-engine-versions
  # --engine mysql --region ap-south-2` (profile infra-provisioner), which
  # lists 8.4.5 through 8.4.11 as available alongside the 8.0.x/5.7.x tracks.
  # Two-part version (not a pinned 8.4.11) matches how "8.0" was specified
  # before — auto_minor_version_upgrade (provider default: true) tracks the
  # latest minor within whichever major.minor family is set here.
  engine_version = "8.4"
  # Required by the provider to perform the 8.0.46 -> 8.4.x major-version
  # upgrade on the already-created live instance. apply_immediately so this
  # runs now instead of waiting for the next maintenance window — safe at
  # this point since the instance has no databases/traffic on it yet.
  allow_major_version_upgrade = true
  apply_immediately           = true
  instance_class              = var.rds_instance_class

  allocated_storage = 20
  storage_type      = "gp3"

  username                    = "admin"
  manage_master_user_password = true
  # Leaving this unset sends a literal null to the RDS API in this provider
  # version instead of resolving the account's default Secrets Manager key —
  # explicit reference avoids the KMSKeyNotAccessibleFault that causes.
  master_user_secret_kms_key_id = "alias/aws/secretsmanager"

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "jewelchat-prod-final"

  tags = { Name = "jewelchat-prod" }
}
