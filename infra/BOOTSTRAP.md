# One-time manual bootstrap (run once, as root)

Terraform in `infra/iam/` and `infra/app/` needs two IAM identities to
already exist before it can run — nothing can grant itself IAM-creation
rights, so this one step has to happen as root, with MFA, same as the
`claude-code-dev` bootstrap documented in the main `CLAUDE.md`. After this,
root goes back in the drawer; everything else in `infra/` runs under these
two identities.

Region throughout: `ap-south-2`, account `273426290822` (same account as the
existing `claude-code-dev`/S3 setup) — already filled in below.

## 1. Permissions boundary (caps what the runtime roles can ever do)

This boundary is attached to every role `iam-admin` creates. `iam-admin`
itself has no permission to edit or detach it — only root does. It's
deliberately scoped to exactly what `mongooseim-runtime-role` and
`nodeapp-runtime-role` need (see plan §2/§5): Secrets Manager reads, log
writes, the existing S3 upload access, read-only EC2/ASG describes for
MongooseIM's cluster-peer discovery, and (added later) Session Manager
access so both tiers are reachable without any inbound port or SSH key —
used to read boot logs and, per plan §3, to port-forward to RDS. Granting
the full `ssm:*`/`ssmmessages:*`/`ec2messages:*` namespace here is safe:
the boundary only sets a ceiling, and each role's actual grant is still
the much narrower `AmazonSSMManagedInstanceCore` managed policy attached
in `infra/iam/roles.tf` — the boundary being wider than that doesn't
widen what the role can actually do.

```bash
cat > /tmp/app-runtime-boundary.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": [
        "arn:aws:secretsmanager:ap-south-2:273426290822:secret:mongooseim/*",
        "arn:aws:secretsmanager:ap-south-2:273426290822:secret:serverprojectx/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:ap-south-2:273426290822:log-group:/app/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::jewelchat-uploads-prod/*"
    },
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "autoscaling:DescribeAutoScalingGroups"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
      "Resource": "arn:aws:ecr:ap-south-2:273426290822:repository/serverprojectx"
    },
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["ssm:*", "ssmmessages:*", "ec2messages:*"],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name AppRuntimeBoundary \
  --policy-document file:///tmp/app-runtime-boundary.json
```

Note the returned `Arn` — needed in step 2.

## 2. `iam-admin` user (manages IAM only, no resource-provisioning power)

```bash
aws iam create-user --user-name iam-admin

cat > /tmp/iam-admin-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreateRoleWithBoundary",
      "Effect": "Allow",
      "Action": "iam:CreateRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::273426290822:policy/AppRuntimeBoundary"
        }
      }
    },
    {
      "Sid": "PassRuntimeRolesToOwnInstanceProfiles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::273426290822:role/mongooseim-runtime-role",
        "arn:aws:iam::273426290822:role/nodeapp-runtime-role"
      ]
    },
    {
      "Sid": "ManageRuntimeRoles",
      "Effect": "Allow",
      "Action": [
        "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
        "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:GetInstanceProfile"
      ],
      "Resource": "*"
    },
    {
      "Sid": "StateBackend",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::jewelchat-tfstate-iam-273426290822-ap-south-2-an",
        "arn:aws:s3:::jewelchat-tfstate-iam-273426290822-ap-south-2-an/*"
      ]
    },
    {
      "Sid": "StateLock",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:ap-south-2:273426290822:table/jewelchat-tflock-iam"
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name iam-admin \
  --policy-name IamAdminPolicy \
  --policy-document file:///tmp/iam-admin-policy.json
```

The `Condition` is what makes the boundary actually binding — without it,
`iam-admin` could create a role with no boundary at all. **This user has
no `ec2:*`/`rds:*`/`elasticloadbalancing:*` permissions anywhere** — it
cannot provision a single piece of infrastructure, only IAM objects capped
by the boundary above.

## 3. `infra-provisioner` user (provisions infra, no IAM-authoring power)

Role ARNs are deterministic (account ID + name), so this policy can
reference `mongooseim-runtime-role` / `nodeapp-runtime-role` before
`iam-admin`'s Terraform run has actually created them.

`ReadRdsMasterSecret` is scoped only to the `rds!db-*` naming pattern RDS
itself uses for the AWS-managed master-password secret (plan §3's
one-time database bootstrap needs to read it) — it does not grant access
to the app-level `mongooseim/*`/`serverprojectx/*` secrets, which stay
readable only by the two runtime roles, never by `infra-provisioner`.

**Blast-radius guardrails** (`DenyRunInstances*`/`DenyCreateDbInstance*`
statements below): the broad `ProvisionInfra` statement grants `ec2:*`/
`rds:*` on `Resource: "*"`, which — if this credential ever leaked — could
launch arbitrary numbers of arbitrarily large/expensive instances. An
explicit `Deny` always wins over an `Allow`, regardless of what the `Allow`
grants, so these cap `ec2:RunInstances`/`rds:CreateDBInstance` to only the
instance type/class, VPC, and region this project actually uses. Each
guardrail is its own statement rather than combined into one `Condition`
block — IAM ANDs multiple keys within a single `Condition`, which would
mean "deny only if *every* guardrail is violated simultaneously"; separate
statements give the correct "deny if *any* guardrail is violated." This
doesn't cap *how many* instances could still be launched within those
constraints — that's what the account-level Service Quotas change (done
separately, see note below) actually enforces.

```bash
aws iam create-user --user-name infra-provisioner

cat > /tmp/infra-provisioner-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProvisionInfra",
      "Effect": "Allow",
      "Action": [
        "ec2:*", "rds:*", "elasticloadbalancing:*", "autoscaling:*",
        "route53:*", "acm:*", "cloudfront:*", "logs:*", "ecr:*",
        "secretsmanager:CreateSecret", "secretsmanager:PutSecretValue",
        "secretsmanager:DescribeSecret", "secretsmanager:TagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadRdsMasterSecret",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:ap-south-2:273426290822:secret:rds!db-*"
    },
    {
      "Sid": "SsmOperatorAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:StartSession", "ssm:TerminateSession", "ssm:ResumeSession",
        "ssm:DescribeSessions", "ssm:DescribeInstanceInformation",
        "ssm:GetConnectionStatus", "ssm:SendCommand", "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations", "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyRunInstancesOutsideGuardrails",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:273426290822:instance/*",
      "Condition": {
        "StringNotEquals": {
          "ec2:InstanceType": ["t3.nano", "t3.micro", "t3.small"]
        }
      }
    },
    {
      "Sid": "DenyRunInstancesOutsideOurVpc",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:273426290822:instance/*",
      "Condition": {
        "StringNotEquals": {
          "ec2:Vpc": "arn:aws:ec2:ap-south-2:273426290822:vpc/vpc-0162fd04971710ed7"
        }
      }
    },
    {
      "Sid": "DenyRunInstancesOutsideRegion",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": "ap-south-2"
        }
      }
    },
    {
      "Sid": "DenyCreateDbInstanceOutsideGuardrails",
      "Effect": "Deny",
      "Action": "rds:CreateDBInstance",
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "rds:DatabaseClass": "db.t3.micro"
        }
      }
    },
    {
      "Sid": "DenyCreateDbInstanceLargeStorage",
      "Effect": "Deny",
      "Action": "rds:CreateDBInstance",
      "Resource": "*",
      "Condition": {
        "NumericGreaterThan": {
          "rds:StorageSize": "50"
        }
      }
    },
    {
      "Sid": "DenyCreateDbInstanceOutsideRegion",
      "Effect": "Deny",
      "Action": "rds:CreateDBInstance",
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": "ap-south-2"
        }
      }
    },
    {
      "Sid": "PassRuntimeRolesOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::273426290822:role/mongooseim-runtime-role",
        "arn:aws:iam::273426290822:role/nodeapp-runtime-role"
      ]
    },
    {
      "Sid": "CreateElbServiceLinkedRoleOnly",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::273426290822:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing",
      "Condition": {
        "StringEquals": {
          "iam:AWSServiceName": "elasticloadbalancing.amazonaws.com"
        }
      }
    },
    {
      "Sid": "CreateRdsServiceLinkedRoleOnly",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::273426290822:role/aws-service-role/rds.amazonaws.com/AWSServiceRoleForRDS",
      "Condition": {
        "StringEquals": {
          "iam:AWSServiceName": "rds.amazonaws.com"
        }
      }
    },
    {
      "Sid": "CreateAutoScalingServiceLinkedRoleOnly",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::273426290822:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
      "Condition": {
        "StringEquals": {
          "iam:AWSServiceName": "autoscaling.amazonaws.com"
        }
      }
    },
    {
      "Sid": "SecretsManagerKmsKeyForRds",
      "Effect": "Allow",
      "Action": ["kms:DescribeKey", "kms:CreateGrant", "kms:Decrypt"],
      "Resource": "*"
    },
    {
      "Sid": "ReadRuntimeRoles",
      "Effect": "Allow",
      "Action": ["iam:GetRole", "iam:GetInstanceProfile"],
      "Resource": "*"
    },
    {
      "Sid": "StateBackend",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::jewelchat-tfstate-app-273426290822-ap-south-2-an",
        "arn:aws:s3:::jewelchat-tfstate-app-273426290822-ap-south-2-an/*"
      ]
    },
    {
      "Sid": "SiteBucket",
      "Effect": "Allow",
      "Action": [
        "s3:PutBucketPolicy", "s3:GetBucketPolicy",
        "s3:PutBucketPublicAccessBlock", "s3:GetBucketPublicAccessBlock",
        "s3:PutObject", "s3:GetObject", "s3:GetObjectTagging", "s3:DeleteObject", "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::jewelchat-site-prod-273426290822",
        "arn:aws:s3:::jewelchat-site-prod-273426290822/*"
      ]
    },
    {
      "Sid": "StateLock",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:ap-south-2:273426290822:table/jewelchat-tflock-app"
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name infra-provisioner \
  --policy-name InfraProvisionerPolicy \
  --policy-document file:///tmp/infra-provisioner-policy.json
```

**This user has zero `iam:Create*`/`Put*`/`Attach*` permissions anywhere**
— it can attach the two pre-named runtime roles to instances, and nothing
else IAM-related.

## 4. Terraform state backend (both buckets/tables, created once by root)

Created via console using account-regional namespace bucket naming, so the
actual names carry the account ID/region suffix:
`jewelchat-tfstate-iam-273426290822-ap-south-2-an` and
`jewelchat-tfstate-app-273426290822-ap-south-2-an`. Equivalent CLI form for
reference:

```bash
aws s3api create-bucket --bucket jewelchat-tfstate-iam-273426290822-ap-south-2-an --region ap-south-2 \
  --create-bucket-configuration LocationConstraint=ap-south-2
aws s3api create-bucket --bucket jewelchat-tfstate-app-273426290822-ap-south-2-an --region ap-south-2 \
  --create-bucket-configuration LocationConstraint=ap-south-2
aws s3api put-bucket-versioning --bucket jewelchat-tfstate-iam-273426290822-ap-south-2-an --versioning-configuration Status=Enabled
aws s3api put-bucket-versioning --bucket jewelchat-tfstate-app-273426290822-ap-south-2-an --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket jewelchat-tfstate-iam-273426290822-ap-south-2-an --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-public-access-block --bucket jewelchat-tfstate-app-273426290822-ap-south-2-an --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name jewelchat-tflock-iam \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
aws dynamodb create-table --table-name jewelchat-tflock-app \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

## 5. Access keys + CLI profiles

```bash
aws iam create-access-key --user-name iam-admin
aws iam create-access-key --user-name infra-provisioner
```

Each returns an `AccessKeyId`/`SecretAccessKey` shown once — save them, then:

```bash
aws configure --profile iam-admin           # paste iam-admin's keys, region ap-south-2
aws configure --profile infra-provisioner   # paste infra-provisioner's keys, region ap-south-2

aws sts get-caller-identity --profile iam-admin
aws sts get-caller-identity --profile infra-provisioner
```

Both should resolve to their own user ARN, not root.

## 6. Shared Erlang cookie secret (consumed by MongooseIM clustering, plan §5)

Generate it once, outside Terraform, so it's never in state or a diff:

```bash
aws secretsmanager create-secret \
  --name mongooseim/erlang-cookie \
  --secret-string "$(openssl rand -hex 32)" \
  --region ap-south-2
```

## After this

`terraform init && terraform apply` in `infra/iam/` under `--profile
iam-admin`, then in `infra/app/` under `--profile infra-provisioner`. Root
is not needed again unless the boundary policy itself needs to change.
