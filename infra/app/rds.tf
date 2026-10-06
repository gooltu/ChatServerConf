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
  identifier     = "jewelchat-prod"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.rds_instance_class

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
