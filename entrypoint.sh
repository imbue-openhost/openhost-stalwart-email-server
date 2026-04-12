#!/bin/sh
set -e

export STALWART_DATA_DIR="${OPENHOST_APP_DATA_DIR:-/opt/stalwart/data}"
export MAIL_HOSTNAME="${MAIL_HOSTNAME:-localhost}"

mkdir -p "$STALWART_DATA_DIR"

# Generate admin secret on first run
SECRET_FILE="$STALWART_DATA_DIR/.admin_secret"
if [ ! -f "$SECRET_FILE" ]; then
    ADMIN_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
    echo "$ADMIN_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    echo "========================================"
    echo " Admin user: admin"
    echo " Admin pass: $ADMIN_SECRET"
    echo "========================================"
fi
export ADMIN_SECRET=$(cat "$SECRET_FILE")

# First-boot: create "user" role so new accounts get JMAP access
INIT_DONE="$STALWART_DATA_DIR/.initialized"
if [ ! -f "$INIT_DONE" ]; then
    (
        # Wait for Stalwart to accept connections
        for i in $(seq 1 30); do
            if wget -q -O /dev/null http://localhost:8080/ 2>/dev/null; then
                break
            fi
            sleep 1
        done

        AUTH=$(printf 'admin:%s' "$ADMIN_SECRET" | base64)

        # Create "user" role
        wget -q -O /dev/null \
            --header="Content-Type: application/json" \
            --header="Authorization: Basic $AUTH" \
            --post-data='{"type":"role","name":"user"}' \
            http://localhost:8080/api/principal 2>/dev/null || true

        touch "$INIT_DONE"
        echo "First-boot init complete: 'user' role created"
    ) &
fi

exec /usr/local/bin/stalwart --config /opt/stalwart/etc/config.toml
