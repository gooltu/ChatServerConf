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
    # Erlang's TLS client defaults verify_mode to "peer" for any https://
    # pool host and errors out immediately (before even attempting a
    # connection — {options,incompatible,[{verify,verify_peer},
    # {cacerts,undefined}]}, logged only at LOG_DEBUG by
    # ejabberd_auth_http so it's silent at this config's default
    # loglevel="warning") if no CA source is given. cacertfile points at
    # the host EC2 instance's own OS-maintained CA bundle, bind-mounted in
    # below — deliberately not one of the bundles already inside the
    # MongooseIM image (e.g. lib/certifi-<version>/priv/cacerts.pem),
    # since that path is pinned to a dependency version that could shift
    # under us on an image update; the host's bundle updates with AL2023's
    # own ca-certificates package instead.
    [outgoing_pools.http.auth.connection.tls]
      cacertfile = "/etc/ssl/ca-bundle.pem"

[outgoing_pools.http.mongoose_push]
  scope = "global"
  workers = 10
  [outgoing_pools.http.mongoose_push.connection]
    # Same nodeapp_domain/ALB pattern as outgoing_pools.http.auth above, just
    # a different path_prefix — see CLAUDE.md "mod_push_service_mongoosepush"
    # for why this prefix has to be exactly "/mongooseim/pushnotification/".
    host = "https://${nodeapp_domain}"
    path_prefix = "/mongooseim/pushnotification/"
    request_timeout = 2000
    # Same cacertfile requirement as outgoing_pools.http.auth above — every
    # https:// outgoing pool needs this, not just auth.
    [outgoing_pools.http.mongoose_push.connection.tls]
      cacertfile = "/etc/ssl/ca-bundle.pem"

[modules.mod_adhoc]
[modules.mod_disco]
  users_can_see_hidden_services = false
[modules.mod_stream_management]
[modules.mod_presence]
[modules.mod_sic]
[modules.mod_time]

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

[modules.mod_push_service_mongoosepush]
  pool_name = "mongoose_push"
  api_version = "v3"

[modules.mod_event_pusher.push]
  backend = "rdbms"
  virtual_pubsub_hosts = ["pubsub.@HOST@"]

# No mod_offline — mod_mam above already persists every message
# unconditionally, so a real offline-message queue would just duplicate that.
# mod_offline_stub only stops the default <service-unavailable/> bounce that
# ejabberd_sm otherwise sends when a message can't be delivered live; see
# CLAUDE.md "Offline messages bounce unless *something* handles
# offline_message" for the full reasoning.
[modules.mod_offline_stub]
EOF

cat > /opt/mongooseim/conf/vm.args <<EOF
-name mongooseim@$PRIVATE_IP
-setcookie $ERLANG_COOKIE
-kernel inet_dist_listen_min 9100
-kernel inet_dist_listen_max 9200
EOF

# /start.sh (inside the image) unconditionally runs a sed replacing the
# vm.args -name line with "-NODE_TYPE NODE_NAME@NODE_HOST" built from these
# three env vars — so they, not the vm.args file content we bind-mount in,
# actually control the node name. NODE_TYPE must be exactly "name" or
# "sname" (the script splices it straight into the flag, so a value like
# "longnames" produces a nonsense "-longnames" flag and no -name/-sname at
# all — confirmed by reading /start.sh directly, same approach as other
# version-sensitive gotchas in CLAUDE.md). NODE_HOST must be set explicitly
# to our private IP, or it defaults to the container's own hostname -f,
# which won't match what the join_cluster peer discovery below addresses by
# private IP. Heredoc stays single-quoted (no shell expansion at all) so
# nothing in here — including this comment — needs bash-escaping; the
# PRIVATE_IP_PLACEHOLDER token is substituted in afterward instead.
cat > /opt/mongooseim/docker-compose.yml <<'EOF'
services:
  mongooseim:
    image: erlangsolutions/mongooseim:latest
    container_name: mongooseim
    restart: unless-stopped
    environment:
      NODE_TYPE: name
      NODE_HOST: PRIVATE_IP_PLACEHOLDER
      JOIN_CLUSTER: "false"
    network_mode: host
    volumes:
      - ./conf:/member
      - mongooseim_data:/var/lib/mongooseim
      # AL2023's own OS-maintained CA bundle, read-only — see the
      # outgoing_pools.http.*.connection.tls.cacertfile comments above for
      # why this is needed at all.
      - /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem:/etc/ssl/ca-bundle.pem:ro
volumes:
  mongooseim_data:
EOF
sed -i "s/PRIVATE_IP_PLACEHOLDER/$PRIVATE_IP/" /opt/mongooseim/docker-compose.yml

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
