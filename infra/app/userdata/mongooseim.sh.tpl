#!/bin/bash
# Rendered via Terraform templatefile() in asg_mongooseim.tf — the
# interpolated placeholders below are substituted at plan/apply time,
# everything else is literal bash run once at boot on Amazon Linux 2023.
set -euo pipefail
exec > >(tee /var/log/mongooseim-userdata.log) 2>&1

dnf install -y docker jq
systemctl enable --now docker
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

# --- Secrets (fetched at boot, never baked into the AMI) -------------------
DB_CREDS_JSON=$(aws secretsmanager get-secret-value --region ${region} \
  --secret-id mongooseim/db-credentials --query SecretString --output text)
DB_USER=$(echo "$DB_CREDS_JSON" | jq -r .username)
DB_PASS=$(echo "$DB_CREDS_JSON" | jq -r .password)
ERLANG_COOKIE=$(aws secretsmanager get-secret-value --region ${region} \
  --secret-id mongooseim/erlang-cookie --query SecretString --output text)

mkdir -p /opt/mongooseim/conf

# Same shape as the dev conf/mongooseim.toml (see CLAUDE.md) — only the
# values that differ in production are templated here: RDS endpoint/creds,
# and auth.http pointed at the ALB's own DNS name (reaches the Node app
# tier's /mongooseim/ endpoints without any extra internal addressing
# mechanism — see plan §5).
cat > /opt/mongooseim/conf/mongooseim.toml <<EOF
[general]
  loglevel = "warning"
  hosts = ["jewelchat.net"]
  default_server_domain = "jewelchat.net"

[[listen.http]]
  port = 5280
  [[listen.http.handlers.mongoose_bosh_handler]]
    host = "_"
    path = "/http-bind"
  [[listen.http.handlers.mongoose_websocket_handler]]
    host = "_"
    path = "/ws-xmpp"
    timeout = 600_000

[auth]
  methods = ["http"]
  [auth.http]
  [auth.password]
    format = "plain"

[internal_databases.mnesia]

[outgoing_pools.rdbms.default]
  scope = "global"
  workers = 5
  [outgoing_pools.rdbms.default.connection]
    driver = "mysql"
    host = "${rds_endpoint}"
    port = 3306
    database = "mongooseim"
    username = "$DB_USER"
    password = "$DB_PASS"

[outgoing_pools.http.auth]
  scope = "global"
  workers = 10
  [outgoing_pools.http.auth.connection]
    # Deliberately the Node app's own public subdomain, not the ALB's raw
    # DNS name — the ALB routes by Host header, and connecting via the
    # real subdomain means this hits an explicit listener rule rather than
    # depending on default-action fallthrough (see alb.tf). Resolves to
    # the same ALB either way since game.jewelchat.net is just a CNAME to it.
    host = "https://${nodeapp_domain}"
    path_prefix = "/mongooseim/"
    request_timeout = 2000

[modules.mod_roster]
  backend = "rdbms"
[modules.mod_ping]
[modules.mod_vcard]
  host = "vjud.@HOST@"
[modules.mod_carboncopy]

[modules.mod_keystore]
  ram_key_size = 32
  keys = [{name = "token_secret", type = "ram"}]
[modules.mod_auth_token]
  validity_period.access = {value = 5, unit = "minutes"}
  validity_period.refresh = {value = 5, unit = "minutes"}

[modules.mod_mam]
  backend = "rdbms"
  full_text_search = false
  [modules.mod_mam.pm]
  [modules.mod_mam.muc]
    host = "muclight.@HOST@"

[modules.mod_muc_light]
  backend = "rdbms"
  allow_multiple_owners = true
EOF

cat > /opt/mongooseim/conf/vm.args <<EOF
-name mongooseim@$PRIVATE_IP
-setcookie $ERLANG_COOKIE
-kernel inet_dist_listen_min 9100
-kernel inet_dist_listen_max 9200
EOF

cat > /opt/mongooseim/docker-compose.yml <<'EOF'
services:
  mongooseim:
    image: erlangsolutions/mongooseim:latest
    container_name: mongooseim
    restart: unless-stopped
    environment:
      NODE_TYPE: longnames
      JOIN_CLUSTER: "false"
    network_mode: host
    volumes:
      - ./conf:/member
      - mongooseim_data:/var/lib/mongooseim
volumes:
  mongooseim_data:
EOF

cd /opt/mongooseim
docker-compose up -d

# --- Cluster join (plan §5) -------------------------------------------------
# Empty peer list => this is the seed node, nothing more to do. Non-empty
# => attempt to join one discovered peer, with retries (the peer may still
# be booting). Scale mongooseim-asg's desired capacity up by one instance
# at a time — simultaneous joins from multiple new nodes race.
sleep 20

PEER_IDS=$(aws autoscaling describe-auto-scaling-groups --region ${region} \
  --auto-scaling-group-names ${asg_name} \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
  --output text)

for peer_id in $PEER_IDS; do
  if [ "$peer_id" = "$INSTANCE_ID" ]; then
    continue
  fi
  PEER_IP=$(aws ec2 describe-instances --region ${region} --instance-ids "$peer_id" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
  joined=false
  for attempt in 1 2 3 4 5; do
    if docker exec mongooseim mongooseimctl mnesia join_cluster "mongooseim@$PEER_IP"; then
      echo "joined cluster via mongooseim@$PEER_IP"
      joined=true
      break
    fi
    sleep 10
  done
  if [ "$joined" = true ]; then
    break
  fi
done
