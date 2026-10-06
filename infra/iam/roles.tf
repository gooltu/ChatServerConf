# Boundary policy created manually by root (BOOTSTRAP.md step 1) — iam-admin
# can attach it (its own policy requires doing so, via the
# iam:PermissionsBoundary condition) but has no permission to edit or
# detach it. Referenced by ARN directly (deterministic: account ID + fixed
# name) rather than a `data "aws_iam_policy"` name lookup, which would need
# iam:ListPolicies — a permission iam-admin's BOOTSTRAP.md policy
# deliberately doesn't grant, since it isn't needed for anything else here.
locals {
  runtime_boundary_arn = "arn:aws:iam::${var.account_id}:policy/AppRuntimeBoundary"

  assume_role_ec2 = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# --- MongooseIM runtime role ------------------------------------------------
# Attached to every instance in mongooseim-asg (infra/app). Needs: its own
# DB-credential secret, the shared Erlang clustering cookie, log writes, and
# read-only ASG/EC2 describes to discover cluster peers at boot (plan §5) —
# deliberately no mutating EC2/ASG/IAM permissions anywhere here.
resource "aws_iam_role" "mongooseim_runtime" {
  name                 = "mongooseim-runtime-role"
  assume_role_policy   = local.assume_role_ec2
  permissions_boundary = local.runtime_boundary_arn
}

resource "aws_iam_role_policy" "mongooseim_runtime" {
  name = "mongooseim-runtime-policy"
  role = aws_iam_role.mongooseim_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DbAndClusterCookie"
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:mongooseim/db-credentials-*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:mongooseim/erlang-cookie-*",
        ]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/app/mongooseim*"
      },
      {
        # Read-only — used by user-data to find other InService instances in
        # this same ASG and attempt a Mnesia cluster join against one of
        # them. No mutating autoscaling/ec2 permissions anywhere on this role.
        Sid      = "ClusterPeerDiscovery"
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups", "ec2:DescribeInstances"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "mongooseim_runtime" {
  name = "mongooseim-runtime-profile"
  role = aws_iam_role.mongooseim_runtime.name
}

# Lets Session Manager reach the instance without opening any inbound
# port or keeping SSH keys around — needed to read boot/user-data logs
# and, per plan §3, to port-forward to RDS for the one-time schema
# bootstrap. Also requires AppRuntimeBoundary (BOOTSTRAP.md step 1) to
# allow the matching ssmmessages/ec2messages/ssm actions, since the
# boundary intersects with whatever's attached here.
resource "aws_iam_role_policy_attachment" "mongooseim_ssm" {
  role       = aws_iam_role.mongooseim_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- Node app runtime role ---------------------------------------------------
# Attached to every instance in nodeapp-asg (infra/app). Reuses the S3
# upload policy content already designed for jewelchat-uploads-prod (not a
# new grant — same scope as the serverprojectx-s3-uploader user) plus its
# own DB-credential/app-secrets reads and log writes.
resource "aws_iam_role" "nodeapp_runtime" {
  name                 = "nodeapp-runtime-role"
  assume_role_policy   = local.assume_role_ec2
  permissions_boundary = local.runtime_boundary_arn
}

resource "aws_iam_role_policy" "nodeapp_runtime" {
  name = "nodeapp-runtime-policy"
  role = aws_iam_role.nodeapp_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DbAndAppSecrets"
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:serverprojectx/db-credentials-*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:serverprojectx/app-secrets-*",
        ]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/app/nodeapp*"
      },
      {
        # Same scope as the serverprojectx-s3-uploader IAM user's policy —
        # reused here, not widened, now that uploads can originate from this
        # role instead of (or alongside) static keys in .env.
        Sid      = "S3Uploads"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "arn:aws:s3:::jewelchat-uploads-prod/uploads/*"
      },
      {
        # Pull-only access to the app's own ECR repo (infra/app creates the
        # repo itself) — avoids needing git credentials on the instance to
        # build from source at boot (plan §5/userdata/nodeapp.sh.tpl).
        Sid      = "EcrPull"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/serverprojectx"
      },
      {
        # GetAuthorizationToken doesn't support resource-level restriction.
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "nodeapp_runtime" {
  name = "nodeapp-runtime-profile"
  role = aws_iam_role.nodeapp_runtime.name
}

resource "aws_iam_role_policy_attachment" "nodeapp_ssm" {
  role       = aws_iam_role.nodeapp_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
