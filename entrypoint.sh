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

# Fetch the SMTP smarthost relay config from the OpenHost router.  Outbound mail
# must relay through the central email proxy (not direct MX) for multi-tenant
# deliverability + safety.  The router returns the relay creds only to this
# (mailbox) app, authenticated with our app token — the relay password is never
# injected into the app environment.  Best-effort: if unavailable, we log and skip
# relay/custom-domain config (the mailbox still runs).  Writes shell vars into
# $DATA_DIR/.relay_env when configured.
RELAY_ENV="$DATA_DIR/.relay_env"
: > "$RELAY_ENV"
# Holds the relay password — restrict before writing anything into it.
chmod 600 "$RELAY_ENV"
if [ -n "$OPENHOST_ROUTER_URL" ] && [ -n "$OPENHOST_APP_TOKEN" ]; then
    RELAY_JSON=$(curl -s -m 10 -H "Authorization: Bearer $OPENHOST_APP_TOKEN" \
        "$OPENHOST_ROUTER_URL/api/email/relay-config" 2>/dev/null || true)
    if [ -n "$RELAY_JSON" ]; then
        # Parse with python3 (present in the image) and emit shell assignments.
        # The JSON is passed via env (RELAY_JSON), NOT stdin — stdin is consumed by
        # this heredoc (the python source), so json.load(sys.stdin) would read the
        # source, not the response.
        RELAY_JSON="$RELAY_JSON" python3 - "$RELAY_ENV" <<'PYEOF' || true
import json, os, sys, shlex
try:
    data = json.loads(os.environ.get("RELAY_JSON") or "")
except Exception:
    sys.exit(0)
if not isinstance(data, dict) or not data.get("configured"):
    sys.exit(0)
fields = {
    "RELAY_HOST": data.get("smtp_relay_host") or "",
    "RELAY_PORT": str(data.get("smtp_relay_port") or 587),
    "RELAY_USER": data.get("smtp_relay_user") or "",
    "RELAY_PASSWORD": data.get("smtp_relay_password") or "",
    "RELAY_CUSTOM_DOMAIN": data.get("custom_domain") or "",
}
with open(sys.argv[1], "w") as f:
    for k, v in fields.items():
        f.write(f"{k}={shlex.quote(v)}\n")
PYEOF
    else
        echo "Email relay config unavailable from router; skipping smarthost/custom-domain setup"
    fi
fi
# shellcheck disable=SC1090
. "$RELAY_ENV" 2>/dev/null || true

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

# Start the JMAP service proxy sidecar (gates /_jmap_service/* requests on
# permissions, injects owner Basic auth, forwards to Stalwart on :8081).
USER_BASIC_AUTH="$USER_BASIC_AUTH" \
STALWART_UPSTREAM="http://127.0.0.1:8081" \
    /opt/jmap_proxy/.venv/bin/uvicorn jmap_proxy.main:app \
    --host 127.0.0.1 --port 8082 \
    --no-access-log &

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

# Reconcile the outbound SMTP smarthost relay + the delegated custom mail domain,
# on every boot (idempotent upserts) so rotated relay creds and a
# later-added custom domain are picked up.  Skipped entirely when the router
# provided no relay config.  Runs once Stalwart is up on :8081.
if [ -n "$RELAY_HOST" ]; then
    (
        export STALWART_URL="http://localhost:8081"
        export STALWART_USER="admin"
        export STALWART_PASSWORD="$ADMIN_SECRET"
        for i in $(seq 1 60); do
            sleep 1
            stalwart-cli query Domain >/dev/null 2>&1 && break
        done

        # Build the apply plan (NDJSON, one op per line). Uses python3 to emit
        # safe JSON with the fetched relay values. upsert => idempotent re-apply.
        # The plan contains secrets (relay password, owner secret), so restrict it
        # and remove it after applying.
        PLAN_FILE="$DATA_DIR/.relay_plan.ndjson"
        : > "$PLAN_FILE"
        chmod 600 "$PLAN_FILE"
        RELAY_HOST="$RELAY_HOST" RELAY_PORT="$RELAY_PORT" RELAY_USER="$RELAY_USER" \
        RELAY_PASSWORD="$RELAY_PASSWORD" RELAY_CUSTOM_DOMAIN="$RELAY_CUSTOM_DOMAIN" \
        OWNER_EMAIL_USER="$OWNER_EMAIL_USER" OWNER_SECRET="$OWNER_SECRET" \
        python3 - "$PLAN_FILE" <<'PYEOF' || true
import json, os, sys

lines = []

# 1) Outbound smarthost: a Relay MtaRoute pointing at the email proxy, with AUTH.
relay = {
    "@type": "Relay",
    "name": "openhost-smarthost",
    "address": os.environ["RELAY_HOST"],
    "port": int(os.environ.get("RELAY_PORT") or 587),
    "protocol": "smtp",
    "implicitTls": False,
    "allowInvalidCerts": False,
    "authUsername": os.environ.get("RELAY_USER") or "",
    "authSecret": {"@type": "Value", "secret": os.environ.get("RELAY_PASSWORD") or ""},
}
lines.append({"@type": "upsert", "object": "MtaRoute", "matchOn": ["name"],
              "value": {"openhost-smarthost": relay}})

# 2) Bind the relay as the default outbound route (send everything through it).
lines.append({"@type": "update", "object": "MtaOutboundStrategy",
              "value": {"route": {"else": "'openhost-smarthost'"}}})

# 3) Optional delegated custom mail domain + an owner account on it, so the
#    owner can send/receive as their own domain. Idempotent upserts.
custom = (os.environ.get("RELAY_CUSTOM_DOMAIN") or "").strip().lower().rstrip(".")
if custom:
    lines.append({"@type": "upsert", "object": "Domain", "matchOn": ["name"],
                  "value": {"dom-custom": {
                      "name": custom,
                      "certificateManagement": {"@type": "Manual"},
                      "dkimManagement": {"@type": "Automatic"},
                      "dnsManagement": {"@type": "Manual"},
                      "subAddressing": {"@type": "Enabled"},
                  }}})
    lines.append({"@type": "upsert", "object": "Account", "matchOn": ["name", "domainId"],
                  "value": {"usr-custom": {
                      "@type": "User",
                      "name": os.environ.get("OWNER_EMAIL_USER") or "owner",
                      "domainId": "#dom-custom",
                      "credentials": [{"@type": "Password", "secret": os.environ.get("OWNER_SECRET") or ""}],
                      "roles": {"@type": "User"},
                      "permissions": {"@type": "Inherit"},
                      "encryptionAtRest": {"@type": "Disabled"},
                  }}})

with open(sys.argv[1], "w") as f:
    for op in lines:
        f.write(json.dumps(op) + "\n")
PYEOF

        if [ -s "$PLAN_FILE" ]; then
            if stalwart-cli apply --file "$PLAN_FILE" >/dev/null 2>&1; then
                echo "Configured outbound smarthost relay${RELAY_CUSTOM_DOMAIN:+ + custom domain $RELAY_CUSTOM_DOMAIN}"
            else
                echo "WARNING: failed to apply relay/custom-domain config (outbound may fall back to direct MX)"
            fi
        fi
        # The plan carries secrets in plaintext; don't leave it on disk (or in
        # data-dir backups) after it's been applied.
        rm -f "$PLAN_FILE"
    ) &
fi

# Start Stalwart normally in foreground
echo "STALWART_HOSTNAME=$STALWART_HOSTNAME"
exec /usr/local/bin/stalwart --config "$CONFIG_DIR/config.json"
