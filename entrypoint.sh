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

exec /usr/local/bin/stalwart --config /opt/stalwart/etc/config.toml
