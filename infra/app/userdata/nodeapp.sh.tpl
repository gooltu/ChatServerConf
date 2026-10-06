#!/bin/bash
# Rendered via Terraform templatefile() in asg_nodeapp.tf.
#
# Pulls a pre-built image from ECR rather than git-cloning ServerProjextX's
# source and building on boot: building needs private-repo git credentials
# as yet another secret, is slow, and is fragile at boot time. ECR pull
# auth is just this role's IAM permissions — one less secret to manage.
# Building and pushing the image to ECR (`serverprojectx:latest` or a
# specific tag) is a separate deploy step, not part of this Terraform —
# likely owned by the other Claude Code session working on ServerProjextX
# itself.
set -euo pipefail
exec > >(tee /var/log/nodeapp-userdata.log) 2>&1

dnf install -y docker jq
systemctl enable --now docker
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

DB_CREDS_JSON=$(aws secretsmanager get-secret-value --region ${region} \
  --secret-id serverprojectx/db-credentials --query SecretString --output text)
DB_USER=$(echo "$DB_CREDS_JSON" | jq -r .username)
DB_PASS=$(echo "$DB_CREDS_JSON" | jq -r .password)

# Everything else .env needs (Firebase service account fields, legacy
# topicname/memcached/gcmkey, S3 region) lives in one JSON secret so adding
# a field later doesn't mean touching this script — see plan §5/CLAUDE.md.
APP_SECRETS_JSON=$(aws secretsmanager get-secret-value --region ${region} \
  --secret-id serverprojectx/app-secrets --query SecretString --output text)

mkdir -p /opt/nodeapp

cat > /opt/nodeapp/.env <<EOF
NODE_ENV=production
PORT=3000
durl=${rds_endpoint}
dusername=$DB_USER
dpassword=$DB_PASS
AWS_REGION=${region}
EOF

# Flatten the rest of app-secrets straight into .env (Firebase fields,
# legacy topicname/memcached/gcmkey, etc.) without needing to know each key
# name ahead of time here.
echo "$APP_SECRETS_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"' >> /opt/nodeapp/.env

aws ecr get-login-password --region ${region} \
  | docker login --username AWS --password-stdin ${ecr_registry_url}

cat > /opt/nodeapp/docker-compose.yml <<EOF
services:
  app:
    image: ${ecr_repository_url}:latest
    restart: unless-stopped
    network_mode: host
    env_file:
      - /opt/nodeapp/.env
EOF

cd /opt/nodeapp
docker-compose pull
docker-compose up -d
