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

# Start Caddy (CORS + owner-auth proxy on :8080 -> :8081) in background
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

# Reconcile Log tracer path — Stalwart's default points to ephemeral /var/log/stalwart;
# repoint it under $DATA_DIR so logs persist across container restarts. Idempotent.
(
    export STALWART_URL="http://localhost:8081"
    export STALWART_USER="admin"
    export STALWART_PASSWORD="$ADMIN_SECRET"
    for i in $(seq 1 60); do
        sleep 1
        stalwart-cli query Tracer >/dev/null 2>&1 && break
    done
    LOG_ID=$(stalwart-cli query Tracer --no-color 2>/dev/null | awk '$2=="Log"{print $1; exit}')
    if [ -n "$LOG_ID" ]; then
        stalwart-cli update Tracer "$LOG_ID" --field "path=$DATA_DIR/logs" >/dev/null 2>&1 || true
    fi
) &

# Start Stalwart normally in foreground
echo "STALWART_HOSTNAME=$STALWART_HOSTNAME"
exec /usr/local/bin/stalwart --config "$CONFIG_DIR/config.json"
