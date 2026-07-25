#!/bin/sh
set -e

DEFAULT_DOMAIN="${OPENHOST_ZONE_DOMAIN:-localhost}"
APP_HOSTNAME="${OPENHOST_APP_NAME:+${OPENHOST_APP_NAME}.${DEFAULT_DOMAIN}}"
export MAIL_HOSTNAME="${MAIL_HOSTNAME:-${APP_HOSTNAME:-$DEFAULT_DOMAIN}}"
# Stable hostname for cluster node ID — without this, every container restart
# creates a new node entry (since podman gives each container a random hostname)
export STALWART_HOSTNAME="${APP_HOSTNAME:-$MAIL_HOSTNAME}"
OWNER_EMAIL_USER="${OWNER_EMAIL_USER:-owner}"
OWNER_EMAIL_DOMAIN="${OWNER_EMAIL_DOMAIN:-$DEFAULT_DOMAIN}"
DATA_DIR="${OPENHOST_APP_DATA_DIR:-/var/lib/stalwart}"
CONFIG_DIR="/etc/stalwart"

mkdir -p "$DATA_DIR"
mkdir -p "$DATA_DIR/logs"

# Generate config.json — path is a directory Stalwart will create for its SQLite files
cat > "$CONFIG_DIR/config.json" <<EOF
{"@type":"Sqlite","path":"$DATA_DIR/db"}
EOF

# Generate admin secret on first run
SECRET_FILE="$DATA_DIR/.admin_secret"
if [ ! -f "$SECRET_FILE" ]; then
    ADMIN_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
    echo "$ADMIN_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    echo "========================================"
    echo " Admin user: admin"
    echo " Admin pass: $ADMIN_SECRET"
    echo "========================================"
fi
ADMIN_SECRET=$(cat "$SECRET_FILE")
export STALWART_RECOVERY_ADMIN="admin:$ADMIN_SECRET"

# Fixed owner email password (both email server and webmail share this;
# access is gated by OpenHost owner auth, not this password)
OWNER_SECRET="${OWNER_EMAIL_PASSWORD:-openhost-owner-email}"

# Template the Caddyfile with auth tokens
ADMIN_BASIC_AUTH=$(printf 'admin:%s' "$ADMIN_SECRET" | base64)
USER_BASIC_AUTH=$(printf '%s:%s' "$OWNER_EMAIL_USER" "$OWNER_SECRET" | base64)
sed -e "s|{{ADMIN_BASIC_AUTH}}|$ADMIN_BASIC_AUTH|g" \
    -e "s|{{USER_BASIC_AUTH}}|$USER_BASIC_AUTH|g" \
    /etc/caddy/Caddyfile.template > /etc/caddy/Caddyfile

# Template the owner-login page with admin secret (page is only served to authenticated owners)
sed -e "s|{{ADMIN_SECRET}}|$ADMIN_SECRET|g" \
    /opt/stalwart/static/owner-login.html > /opt/stalwart/static/owner-login-rendered.html

# First-boot: start in recovery mode, apply initial config via CLI
INIT_DONE="$DATA_DIR/.initialized"
if [ ! -f "$INIT_DONE" ]; then
  echo "First boot detected: starting Stalwart in recovery mode to apply initial configuration"
    export STALWART_RECOVERY_MODE=1

    /usr/local/bin/stalwart --config "$CONFIG_DIR/config.json" &
    STALWART_PID=$!

    # Wait for recovery mode listener on port 8080
    for i in $(seq 1 30); do
        if curl -s -o /dev/null -w '' http://localhost:8080/ 2>/dev/null; then
            break
        fi
        sleep 1
    done

    export STALWART_URL="http://localhost:8080"
    export STALWART_USER="admin"
    export STALWART_PASSWORD="$ADMIN_SECRET"

    # Apply initial plan: domain, settings, listeners, owner account
    stalwart-cli apply --file /dev/stdin <<PLAN
{"@type":"create","object":"Domain","value":{"dom-a":{"name":"$OWNER_EMAIL_DOMAIN"}}}
{"@type":"update","object":"SystemSettings","value":{"defaultDomainId":"#dom-a","defaultHostname":"$MAIL_HOSTNAME"}}
{"@type":"create","object":"NetworkListener","value":{"http-listener":{"name":"http","bind":{"0.0.0.0:8081":true},"protocol":"http","useTls":false},"smtp-listener":{"name":"smtp","bind":{"0.0.0.0:25":true},"protocol":"smtp","useTls":false}}}
{"@type":"create","object":"Account","value":{"owner-acct":{"@type":"User","name":"$OWNER_EMAIL_USER","domainId":"#dom-a","credentials":{"0":{"@type":"Password","secret":"$OWNER_SECRET"}}}}}
PLAN

    touch "$INIT_DONE"
    echo "First-boot init complete: domain, listeners, and owner account created"

    # Stop recovery-mode Stalwart
    kill "$STALWART_PID"
    wait "$STALWART_PID" 2>/dev/null || true
    unset STALWART_RECOVERY_MODE
fi

# Per-container token shared between the sidecar and the Stalwart webhook so a
# delivery.auth-failed event can authenticate to the sidecar's relay-webhook
# endpoint. Generated BEFORE the relay-config pass below so configure-relay.sh
# (which only registers the webhook when RELAY_WEBHOOK_TOKEN is set) can create
# it. Persisted so it's stable across the sidecar + configure-relay runs.
WEBHOOK_TOKEN_FILE="$DATA_DIR/.relay_webhook_token"
if [ ! -f "$WEBHOOK_TOKEN_FILE" ]; then
    head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32 > "$WEBHOOK_TOKEN_FILE"
    chmod 600 "$WEBHOOK_TOKEN_FILE"
fi
RELAY_WEBHOOK_TOKEN="$(cat "$WEBHOOK_TOKEN_FILE")"
export RELAY_WEBHOOK_TOKEN

# Apply the OpenHost email relay config (smarthost route, port, DKIM-disable,
# webhook) and reconcile the log path BEFORE the main Stalwart starts, then
# restart Stalwart so it reads them. Stalwart caches the MtaOutboundStrategy at
# startup and does NOT hot-reload it when changed via the admin API, so applying
# it against the long-running server (the old approach) left outbound on the
# default MX route until the next restart — external mail timed out on the
# provider-blocked port 25. So we run a throwaway normal-mode Stalwart on :8081,
# apply the config against its full admin API (recovery mode's API is unreliable),
# stop it, and let the main Stalwart below read the persisted config from its
# first start. Runs every boot, so rotated relay credentials are still applied.
# Best-effort: never blocks boot.
(
    /usr/local/bin/stalwart --config "$CONFIG_DIR/config.json" >/dev/null 2>&1 &
    PRESTART_PID=$!
    export STALWART_URL="http://localhost:8081"
    export STALWART_USER="admin"
    export STALWART_PASSWORD="$ADMIN_SECRET"
    up=0
    for i in $(seq 1 60); do
        if stalwart-cli query MtaOutboundStrategy >/dev/null 2>&1; then up=1; break; fi
        sleep 1
    done
    if [ "$up" = "1" ]; then
        /usr/local/bin/configure-relay.sh || echo "relay-config: setup failed (continuing)"
        # Reconcile the Log tracer path to the persistent volume (was a separate
        # post-start pass; do it here so it also survives into the main start).
        LOG_ID=$(stalwart-cli query Tracer --no-color 2>/dev/null | awk '$2=="Log"{print $1; exit}')
        if [ -n "$LOG_ID" ]; then
            stalwart-cli update Tracer "$LOG_ID" --field "path=$DATA_DIR/logs" >/dev/null 2>&1 || true
        fi
    else
        echo "relay-config: pre-start admin API did not come up; skipping"
    fi
    kill "$PRESTART_PID" 2>/dev/null || true
    wait "$PRESTART_PID" 2>/dev/null || true
    # Give the OS a moment to release the listener sockets (:8081, :25) the
    # throwaway server held, so the main Stalwart below can bind them.
    sleep 2
    unset STALWART_URL STALWART_USER STALWART_PASSWORD
)


# Start the JMAP service proxy sidecar (gates /_jmap_service/* requests on
# permissions, injects owner Basic auth, forwards to Stalwart on :8081). Also
# serves /_email/relay-webhook (outbound relay re-sync on Stalwart's
# delivery.auth-failed event). Inbound mail arrives directly on the SMTP :25
# listener, not through the sidecar.
USER_BASIC_AUTH="$USER_BASIC_AUTH" \
STALWART_UPSTREAM="http://127.0.0.1:8081" \
RELAY_WEBHOOK_TOKEN="$RELAY_WEBHOOK_TOKEN" \
    /opt/jmap_proxy/.venv/bin/uvicorn jmap_proxy.main:app \
    --host 127.0.0.1 --port 8082 \
    --no-access-log &

# Start Caddy (CORS + owner-auth proxy on :8080 -> :8081) in background
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

# Start Stalwart normally in foreground (reads the relay config applied above).
echo "STALWART_HOSTNAME=$STALWART_HOSTNAME"
exec /usr/local/bin/stalwart --config "$CONFIG_DIR/config.json"
