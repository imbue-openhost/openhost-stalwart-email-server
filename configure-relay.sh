#!/bin/sh
# Configure Stalwart's outbound smarthost from the OpenHost email relay-config.
#
# Fetches GET $OPENHOST_ROUTER_URL/api/email/relay-config with the app token
# (only the mailbox app is authorized to read it). When email is configured on
# the instance, applies an MtaRoute (@type Relay) pointing at the openhost-email-
# proxy submission smarthost (implicit TLS on 465) authenticated with the
# per-instance HMAC credential (user=zone, password=HMAC), then points the
# outbound strategy's default route at it (local mail still delivered locally).
#
# Idempotent: MtaRoute is created-or-updated by name; the strategy singleton is
# updated in place. No-op (exit 0) when the router is unreachable or email is not
# configured, so the mail server still boots.
#
# Requires: curl, python3 (for JSON parsing), stalwart-cli, and a running
# Stalwart admin API on $STALWART_URL.
set -eu

ROUTER_URL="${OPENHOST_ROUTER_URL:-}"
APP_TOKEN="${OPENHOST_APP_TOKEN:-}"
if [ -z "$ROUTER_URL" ] || [ -z "$APP_TOKEN" ]; then
    echo "relay-config: no router URL / app token; skipping outbound relay setup"
    exit 0
fi

RESP="$(curl -fsS --max-time 15 \
    -H "Authorization: Bearer $APP_TOKEN" \
    "$ROUTER_URL/api/email/relay-config" 2>/dev/null || true)"
if [ -z "$RESP" ]; then
    echo "relay-config: router unreachable or returned nothing; skipping"
    exit 0
fi

# Parse with python3 (available in the image) and emit shell assignments.
EVAL="$(printf '%s' "$RESP" | python3 -c '
import json, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    print("CONFIGURED=0"); sys.exit(0)
if not d.get("configured"):
    print("CONFIGURED=0"); sys.exit(0)
host = d.get("smtp_relay_host") or ""
port = d.get("smtp_relay_port") or 465
user = d.get("smtp_relay_user") or ""
pw = d.get("smtp_relay_password") or ""
if not host or not user or not pw:
    print("CONFIGURED=0"); sys.exit(0)
print("CONFIGURED=1")
print(f"RELAY_HOST={shlex.quote(host)}")
print(f"RELAY_PORT={int(port)}")
print(f"RELAY_USER={shlex.quote(user)}")
print(f"RELAY_PW={shlex.quote(pw)}")
')"
eval "$EVAL"

if [ "${CONFIGURED:-0}" != "1" ]; then
    echo "relay-config: email not configured on this instance; skipping outbound relay setup"
    exit 0
fi

# Implicit TLS when the relay port is the submission-over-TLS port (465).
if [ "$RELAY_PORT" = "465" ]; then
    IMPLICIT_TLS=true
else
    IMPLICIT_TLS=false
fi

echo "relay-config: configuring outbound smarthost $RELAY_USER@$RELAY_HOST:$RELAY_PORT (implicitTls=$IMPLICIT_TLS)"

# Create-or-update the relay route by name ("openhost-smarthost"). Delete any
# prior instance first so re-provisioning (e.g. rotated credential) is idempotent
# across reboots; ignore errors when it doesn't yet exist.
stalwart-cli delete MtaRoute openhost-smarthost >/dev/null 2>&1 || true
stalwart-cli apply --file /dev/stdin <<PLAN
{"@type":"create","object":"MtaRoute","value":{"openhost-smarthost":{"@type":"Relay","name":"openhost-smarthost","description":"OpenHost email proxy smarthost","address":"$RELAY_HOST","port":$RELAY_PORT,"protocol":"smtp","implicitTls":$IMPLICIT_TLS,"allowInvalidCerts":false,"authUsername":"$RELAY_USER","authSecret":{"@type":"Value","secret":"$RELAY_PW"}}}}
PLAN

# Point the default outbound route at the smarthost; keep local mail local.
stalwart-cli update MtaOutboundStrategy singleton \
    --field 'route={"match":[{"if":"is_local_domain('"'"''"'"', rcpt_domain)","then":"'"'"'local'"'"'"}],"else":"'"'"'openhost-smarthost'"'"'"}'

echo "relay-config: outbound smarthost configured"

# Register a Stalwart webhook that fires on outbound relay AUTH failure
# (delivery.auth-failed) so a rotated RELAY_SECRET is picked up immediately: the
# sidecar re-runs this script on receipt instead of waiting for the next boot.
# Idempotent — delete any prior hook first. Authenticated to the sidecar with a
# per-container bearer token (RELAY_WEBHOOK_TOKEN, generated at boot). Skipped if
# no token is set (e.g. reconfigure invoked from the webhook itself, to avoid a
# re-registration loop).
if [ -n "${RELAY_WEBHOOK_TOKEN:-}" ] && [ "${SKIP_WEBHOOK_REGISTER:-0}" != "1" ]; then
    WEBHOOK_URL="http://127.0.0.1:8082/_email/relay-webhook"
    stalwart-cli delete WebHook openhost-relay-auth >/dev/null 2>&1 || true
    stalwart-cli apply --file /dev/stdin <<HOOK
{"@type":"create","object":"WebHook","value":{"openhost-relay-auth":{"url":"$WEBHOOK_URL","events":["delivery.auth-failed"],"eventsPolicy":"include","level":"info","signatureKey":{"@type":"None"},"httpAuth":{"@type":"Bearer","bearerToken":{"@type":"Value","secret":"$RELAY_WEBHOOK_TOKEN"}},"httpHeaders":{},"throttle":"30s","enable":true}}}
HOOK
    echo "relay-config: registered delivery.auth-failed webhook -> sidecar"
fi
